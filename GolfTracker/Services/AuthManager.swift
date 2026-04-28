import Foundation
import AuthenticationServices
import Combine
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
final class AuthManager: NSObject, ObservableObject {
    static let shared = AuthManager()

    @Published private(set) var session: AuthSession?
    @Published private(set) var isSigningIn = false

    private let supabase = SupabaseManager.shared
    private var sessionListener: Task<Void, Never>?

    private override init() {
        super.init()
        // Pick up whatever session the SDK has persisted from a previous launch.
        if let s = supabase.auth.currentSession {
            self.session = AuthSession(s)
            WatchConnectivityManager.shared.sendAuthSession(self.session)
        }
        startSessionListener()
    }

    var isSignedIn: Bool { session != nil }
    var currentUserId: String? { session?.userId }
    var currentAccessToken: String? { session?.accessToken }

    /// SDK auto-refreshes; this call returns the current access token if the SDK
    /// has a valid session. Kept async to preserve the legacy completion-handler
    /// API used by SupabaseSync.
    func validAccessToken(completion: @escaping (Result<String, AuthError>) -> Void) {
        Task {
            do {
                let s = try await supabase.auth.session
                await MainActor.run { completion(.success(s.accessToken)) }
            } catch {
                await MainActor.run { completion(.failure(.supabaseRejected(error.localizedDescription))) }
            }
        }
    }

    /// Forces a refresh. Mostly useful after a 401 retry path.
    func refreshSession(completion: @escaping (Result<AuthSession, AuthError>) -> Void) {
        Task {
            do {
                let s = try await supabase.auth.refreshSession()
                let mirror = AuthSession(s)
                await MainActor.run {
                    self.session = mirror
                    WatchConnectivityManager.shared.sendAuthSession(mirror)
                    completion(.success(mirror))
                }
            } catch {
                await MainActor.run { completion(.failure(.supabaseRejected(error.localizedDescription))) }
            }
        }
    }

    // MARK: - Sign In With Apple

    func signInWithApple(from anchor: ASPresentationAnchor? = nil, completion: @escaping (Result<AuthSession, AuthError>) -> Void) {
        isSigningIn = true
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        let coordinator = SIWACoordinator(anchor: anchor) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let identityToken):
                Task {
                    do {
                        let s = try await self.supabase.auth.signInWithIdToken(
                            credentials: .init(provider: .apple, idToken: identityToken)
                        )
                        let mirror = AuthSession(s)
                        await MainActor.run {
                            self.isSigningIn = false
                            self.session = mirror
                            WatchConnectivityManager.shared.sendAuthSession(mirror)
                            completion(.success(mirror))
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
    private func startSessionListener() {
        sessionListener?.cancel()
        sessionListener = Task { [weak self] in
            guard let self = self else { return }
            for await (_, sdkSession) in self.supabase.auth.authStateChanges {
                let mirror = sdkSession.map(AuthSession.init)
                await MainActor.run {
                    self.session = mirror
                    WatchConnectivityManager.shared.sendAuthSession(mirror)
                }
            }
        }
    }
}

// MARK: - AuthSession ↔ SDK Session bridge

extension AuthSession {
    /// Build our wire-format session from the SDK's Session type. This mirror
    /// is what gets sent to the Watch via WatchConnectivity.
    init(_ s: Supabase.Session) {
        self.init(
            accessToken: s.accessToken,
            refreshToken: s.refreshToken,
            expiresAt: Date(timeIntervalSince1970: s.expiresAt),
            userId: s.user.id.uuidString
        )
    }
}

// MARK: - Sign in with Apple coordinator

private final class SIWACoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let anchor: ASPresentationAnchor?
    private let completion: (Result<String, AuthError>) -> Void

    init(anchor: ASPresentationAnchor?, completion: @escaping (Result<String, AuthError>) -> Void) {
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
        completion(.success(token))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        completion(.failure(.network(error)))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        if let anchor = anchor { return anchor }
        return ASPresentationAnchor()
    }
}
