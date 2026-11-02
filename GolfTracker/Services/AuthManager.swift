import Foundation
import AuthenticationServices
import Combine
import os
import Supabase

enum AuthError: Error, LocalizedError {
    case noIdentityToken
    case supabaseRejected(String)
    case network(Error)
    case decode

    var errorDescription: String? {
        switch self {
        case .noIdentityToken: return "Apple did not return an identity token."
        case .supabaseRejected(let msg): return "Sign in failed: \(msg)"
        case .network(let err): return err.localizedDescription
        case .decode: return "Could not read sign-in response."
        }
    }
}

/// iPhone-side auth. Backed by the supabase-swift SDK (which handles token
/// refresh, retry, persistence internally). Public API surface preserved so
/// existing callers don't change. Mirrors the auth session to the Watch via
/// `WatchConnectivityManager.sendAuthSession` whenever it changes.
///
/// Read from every queue (sync and logging ask who is signed in), written on
/// main. `session` is main's published copy for the UI; everything else reads
/// `currentSession`, a lock-backed mirror it keeps.
final class AuthManager: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = AuthManager()

    @MainActor @Published private(set) var session: AuthSession? {
        didSet { mirror.withLock { [session] in $0 = session } }
    }
    @MainActor @Published private(set) var isSigningIn = false

    private let supabase = SupabaseManager.shared
    private let mirror = OSAllocatedUnfairLock<AuthSession?>(initialState: nil)

    private override init() {
        super.init()
        // Pick up whatever session the SDK has persisted from a previous launch.
        let persisted = supabase.auth.currentSession.map(AuthSession.init)
        mirror.withLock { $0 = persisted }
        if let persisted {
            WatchConnectivityManager.shared.sendAuthSession(persisted)
            Task { @MainActor in
                if self.session == nil { self.session = persisted }
            }
        }
        startSessionListener()
    }

    /// The session as last applied, from any thread.
    var currentSession: AuthSession? { mirror.withLock { $0 } }
    var isSignedIn: Bool { currentSession != nil }
    var currentUserId: String? { currentSession?.userId }
    var currentAccessToken: String? { currentSession?.accessToken }

    // MARK: - Sign In With Apple

    @MainActor
    func signInWithApple(from anchor: ASPresentationAnchor? = nil, completion: @escaping (Result<AuthSession, AuthError>) -> Void) {
        isSigningIn = true
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        let coordinator = SIWACoordinator(anchor: anchor) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let payload):
                Task {
                    do {
                        let s = try await self.supabase.auth.signInWithIdToken(
                            credentials: .init(provider: .apple, idToken: payload.identityToken)
                        )
                        let mirror = AuthSession(s)
                        await MainActor.run {
                            self.isSigningIn = false
                            self.session = mirror
                            WatchConnectivityManager.shared.sendAuthSession(mirror)
                            completion(.success(mirror))
                        }
                        // Apple only ships the user's name on the *very first*
                        // sign-in for an app — any subsequent sign-in returns
                        // nil for fullName. Capture it now or lose it forever.
                        if let firstName = payload.firstName, !firstName.isEmpty {
                            try? await PlaygroupService.shared.upsertMyProfile(
                                firstName: firstName,
                                displayName: nil
                            )
                        }
                    } catch {
                        await MainActor.run {
                            self.isSigningIn = false
                            completion(.failure(.supabaseRejected(error.localizedDescription)))
                        }
                    }
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    self.isSigningIn = false
                    completion(.failure(error))
                }
            }
        }
        controller.delegate = coordinator
        controller.presentationContextProvider = coordinator
        self.pendingCoordinator = coordinator
        controller.performRequests()
    }

    private var pendingCoordinator: SIWACoordinator?

    // MARK: - Sign out

    @MainActor
    func signOut() {
        Task {
            try? await supabase.auth.signOut()
            await MainActor.run {
                self.session = nil
                WatchConnectivityManager.shared.sendAuthSession(nil)
            }
        }
    }

    // MARK: - Live session listener

    /// SDK fires auth state change events (sign-in, sign-out, token refresh).
    /// Mirror those into our @Published session and the watch.
    /// Runs for the life of the process (the singleton never goes away).
    private func startSessionListener() {
        Task {
            for await (_, sdkSession) in self.supabase.auth.authStateChanges {
                let mirror = sdkSession.map(AuthSession.init)
                await MainActor.run {
                    self.session = mirror
                    WatchConnectivityManager.shared.sendAuthSession(mirror)
                    if let mirror = mirror {
                        // iOS keeps Realtime always-on once signed in. Cross-
                        // device sync needs to work even when the user isn't
                        // currently in an active round (e.g. watch starts a
                        // round while the iPhone is on the rounds list view —
                        // without this, the new round wouldn't appear until
                        // the iPhone entered an active-round screen). On
                        // foreground iPhone the WebSocket is cheap (~5 MB/mo
                        // for heartbeats); the round-scoped lifecycle was a
                        // watchOS-only battery concern.
                        RealtimeSync.shared.start(forUserId: mirror.userId)
                        // Catch up on any rounds-related rows we missed while
                        // not subscribed (Realtime postgres-changes are
                        // live-only — they don't replay). Idempotent.
                        // Then download any history this device lacks (a
                        // reinstall or new phone starts empty).
                        Task {
                            await RealtimeSync.shared.reconcileRoundsWithSupabase()
                            await RealtimeSync.shared.syncMissingRoundsWithSupabase()
                        }
                        // Retry TestModeService bootstrap whenever a real
                        // session arrives. start() is idempotent — bails
                        // if it's already running.
                        TestModeService.shared.start()
                    } else {
                        RealtimeSync.shared.stop()
                    }
                }
            }
        }
    }
}

// MARK: - Sign in with Apple coordinator

struct SIWAPayload {
    let identityToken: String
    /// Only present on the very first sign-in for an Apple ID against this
    /// app — Apple deliberately stops sending the name on subsequent
    /// sign-ins to protect privacy. Capture-or-lose-it.
    let firstName: String?
}

private final class SIWACoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let anchor: ASPresentationAnchor?
    private let completion: (Result<SIWAPayload, AuthError>) -> Void

    init(anchor: ASPresentationAnchor?, completion: @escaping (Result<SIWAPayload, AuthError>) -> Void) {
        self.anchor = anchor
        self.completion = completion
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else {
            completion(.failure(.noIdentityToken))
            return
        }
        let firstName = credential.fullName?.givenName
        completion(.success(SIWAPayload(identityToken: token, firstName: firstName)))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        completion(.failure(.network(error)))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        if let anchor = anchor { return anchor }
        return ASPresentationAnchor()
    }
}
