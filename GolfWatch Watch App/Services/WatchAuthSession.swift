import CryptoKit
import Foundation
import os
import Supabase

/// Watch-side auth, backed by the supabase-swift SDK. Receives session updates
/// from the iPhone via `WatchConnectivityManager` and feeds them into the
/// SDK via `setSession`. The SDK handles token refresh internally.
///
/// Public API surface preserved so existing callers (SupabaseUploader,
/// OSMCourseService) don't change.
///
/// Read from every queue (uploads and sync ask who is signed in), written on
/// main. `session` is main's published copy for the UI; everything else reads
/// `currentSession`, a lock-backed mirror it keeps.
final class WatchAuthSession: ObservableObject, @unchecked Sendable {
    static let shared = WatchAuthSession()

    private let supabase = SupabaseManager.shared
    private let mirror = OSAllocatedUnfairLock<AuthSession?>(initialState: nil)

    /// Mirror of the latest session received from the iPhone, kept locally so
    /// callers can read access token / user id synchronously without awaiting
    /// the SDK. The SDK's own session is the authoritative refresh target.
    ///
    /// `@Published` so the home screen can distinguish "not signed in yet" from
    /// "signed in, clubs still loading" and flip the moment a session lands.
    /// Both runtime assignments below already hop to the main actor; the one in
    /// `init` runs before any observer exists. Note this is deliberately NOT
    /// exposed through `onSessionChanged`, which is a single-assignment closure
    /// already owned by `WatchDataStore` for club hydration — a second consumer
    /// taking it would silently clobber the first.
    @MainActor @Published private(set) var session: AuthSession? {
        didSet { mirror.withLock { [session] in $0 = session } }
    }

    /// Notified on main whenever the session changes (sign-in, refresh,
    /// sign-out).
    @MainActor var onSessionChanged: ((AuthSession?) -> Void)?

    private init() {
        // Pick up whatever the SDK has persisted from a previous launch.
        let persisted = supabase.auth.currentSession.map(AuthSession.init)
        mirror.withLock { $0 = persisted }
        Task { @MainActor in
            if self.session == nil, let persisted { self.session = persisted }
        }
        startSessionListener()
    }

    /// The session as last applied, from any thread.
    var currentSession: AuthSession? { mirror.withLock { $0 } }
    var isSignedIn: Bool { currentSession != nil }
    var currentUserId: String? { currentSession?.userId }

    /// SHA-256 of the refresh token in the last session the phone sent
    /// (hashed because UserDefaults is not the keychain).
    private static let lastPhoneSessionKey = "lastPhoneSessionFingerprint"

    /// A session from the iPhone, over either WC path. The same session
    /// arrives many times — the phone's context carries it on every update to
    /// any key, and it is re-read at every launch — and by then the SDK here
    /// may have refreshed past it. Setting it again would put a spent refresh
    /// token back in charge, and the next refresh with it trips Supabase's
    /// reuse detection, which revokes the session on both devices. So a
    /// repeat is ignored unless the watch has no session at all.
    func receiveFromPhone(_ newSession: AuthSession?) {
        guard let newSession else {
            UserDefaults.standard.removeObject(forKey: Self.lastPhoneSessionKey)
            apply(nil)
            return
        }
        let fingerprint = SHA256.hash(data: Data(newSession.refreshToken.utf8))
            .map { String(format: "%02x", $0) }.joined()
        if isSignedIn && UserDefaults.standard.string(forKey: Self.lastPhoneSessionKey) == fingerprint { return }
        UserDefaults.standard.set(fingerprint, forKey: Self.lastPhoneSessionKey)
        apply(newSession)
    }

    /// Replace the stored session and push it into the SDK so it can take
    /// over refresh.
    private func apply(_ newSession: AuthSession?) {
        Task {
            if let s = newSession {
                do {
                    _ = try await self.supabase.auth.setSession(
                        accessToken: s.accessToken,
                        refreshToken: s.refreshToken
                    )
                } catch {
                    dprint("⌚ [WatchAuthSession] setSession failed: \(error)")
                }
            } else {
                try? await self.supabase.auth.signOut()
            }
            await MainActor.run {
                self.session = newSession
                self.onSessionChanged?(newSession)
            }
        }
    }

    /// Throttled trigger to ask the iPhone for the current session via WC.
    /// Called by the SDK error logger when a Supabase call fails with a
    /// 401-like error — common cause is a stale refresh token after the
    /// watch's been offline; the iPhone usually has a fresh one. Fires at
    /// most once every `requestRefreshThrottleSeconds` so a flurry of
    /// failing calls doesn't spam the iPhone.
    private static let requestRefreshThrottleSeconds: TimeInterval = 10
    private let lastRefreshRequestAt = OSAllocatedUnfairLock<Date>(initialState: .distantPast)
    func requestRefreshFromPhone() {
        let now = Date()
        let due = lastRefreshRequestAt.withLock { last in
            guard now.timeIntervalSince(last) >= Self.requestRefreshThrottleSeconds else { return false }
            last = now
            return true
        }
        guard due else { return }
        WatchConnectivityManager.shared.requestAuthSessionRefresh()
    }

    // MARK: - Session listener

    /// Runs for the life of the process (the singleton never goes away).
    private func startSessionListener() {
        Task {
            for await (_, sdkSession) in self.supabase.auth.authStateChanges {
                let mirror = sdkSession.map(AuthSession.init)
                await MainActor.run {
                    self.session = mirror
                    self.onSessionChanged?(mirror)
                    // Realtime lifecycle is round-scoped (started by ActiveRound
                    // view onAppear, not at sign-in time). Sign-out tears
                    // it down regardless.
                    if mirror == nil {
                        RealtimeSync.shared.stop()
                    }
                }
            }
        }
    }
}

