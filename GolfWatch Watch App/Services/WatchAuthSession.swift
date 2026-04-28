import Foundation
import Supabase

/// Watch-side auth, backed by the supabase-swift SDK. Receives session updates
/// from the iPhone via `WatchConnectivityManager` and feeds them into the
/// SDK via `setSession`. The SDK handles token refresh internally.
///
/// Public API surface preserved so existing callers (SupabaseUploader,
/// OSMCourseService) don't change.
final class WatchAuthSession {
    static let shared = WatchAuthSession()

    private let supabase = SupabaseManager.shared
    private let queue = DispatchQueue(label: "watch-auth-session")

    /// Mirror of the latest session received from the iPhone, kept locally so
    /// callers can read access token / user id synchronously without awaiting
    /// the SDK. The SDK's own session is the authoritative refresh target.
    private(set) var session: AuthSession?

    /// Notified whenever the session changes (sign-in, refresh, sign-out).
    var onSessionChanged: ((AuthSession?) -> Void)?

    private init() {
        // Pick up whatever the SDK has persisted from a previous launch.
        if let s = supabase.auth.currentSession {
            self.session = AuthSession(s)
        }
        startSessionListener()
    }

    var isSignedIn: Bool { session != nil }
    var currentUserId: String? { session?.userId }

    /// Replace the stored session (called when iPhone forwards a new one).
    /// Pushes into the SDK so it can take over refresh.
    func apply(_ newSession: AuthSession?) {
        queue.async { [weak self] in
            guard let self = self else { return }
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
    }

    /// Returns a non-expired access token. SDK handles refresh internally;
    /// we just await `auth.session` which refreshes if needed.
    func validAccessToken(completion: @escaping (Result<String, WatchAuthError>) -> Void) {
        Task {
            do {
                let s = try await supabase.auth.session
                await MainActor.run { completion(.success(s.accessToken)) }
            } catch {
                await MainActor.run { completion(.failure(.refreshFailed(0))) }
            }
        }
    }

    /// Force a refresh (used after a 401 retry path).
    func forceRefresh(completion: @escaping (Result<String, WatchAuthError>) -> Void) {
        Task {
            do {
                let s = try await supabase.auth.refreshSession()
                await MainActor.run { completion(.success(s.accessToken)) }
            } catch {
                await MainActor.run { completion(.failure(.refreshFailed(0))) }
            }
        }
    }

    // MARK: - Session listener

    private var sessionListener: Task<Void, Never>?

    private func startSessionListener() {
        sessionListener?.cancel()
        sessionListener = Task { [weak self] in
            guard let self = self else { return }
            for await (_, sdkSession) in self.supabase.auth.authStateChanges {
                let mirror = sdkSession.map(AuthSession.init)
                await MainActor.run {
                    self.session = mirror
                    self.onSessionChanged?(mirror)
                }
            }
        }
    }
}

enum WatchAuthError: Error {
    case notSignedIn
    case badRequest
    case refreshFailed(Int)
}
