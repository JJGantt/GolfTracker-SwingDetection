import Foundation
import AuthenticationServices
import Combine

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

final class AuthManager: NSObject, ObservableObject {
    static let shared = AuthManager()

    @Published private(set) var session: AuthSession?
    @Published private(set) var isSigningIn = false

    private let client = SupabaseClient.shared
    private let keychain = KeychainStore(service: "com.Jared.GolfTracker.auth")

    private override init() {
        super.init()
        self.session = keychain.readSession()
        // Push current session to Watch on launch so a freshly-paired or
        // freshly-relaunched Watch picks it up without needing a new sign-in.
        if let session = self.session {
            WatchConnectivityManager.shared.sendAuthSession(session)
        }
    }

    var isSignedIn: Bool { session != nil }
    var currentUserId: String? { session?.userId }
    var currentAccessToken: String? { session?.accessToken }

    /// Returns a non-expired access token, refreshing first if the current one is
    /// within 5 minutes of expiry. Use this before every Supabase REST call instead
    /// of reading `currentAccessToken` directly.
    func validAccessToken(completion: @escaping (Result<String, AuthError>) -> Void) {
        guard let session = session else {
            completion(.failure(.supabaseRejected("not signed in")))
            return
        }
        if session.expiresAt.timeIntervalSinceNow > 300 {
            completion(.success(session.accessToken))
            return
        }
        refreshSession { result in
            switch result {
            case .success(let s): completion(.success(s.accessToken))
            case .failure(let e): completion(.failure(e))
            }
        }
    }

    /// Trades the refresh token for a fresh access token (and rotated refresh token).
    /// Updates Keychain + propagates the new session to the Watch.
    func refreshSession(completion: @escaping (Result<AuthSession, AuthError>) -> Void) {
        guard let session = session else {
            completion(.failure(.supabaseRejected("not signed in")))
            return
        }
        let payload: [String: Any] = ["refresh_token": session.refreshToken]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let req = client.authedRequest(path: "/auth/v1/token?grant_type=refresh_token", method: "POST", body: body) else {
            completion(.failure(.network(NSError(domain: "AuthManager", code: -1))))
            return
        }
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error { completion(.failure(.network(error))); return }
            guard let data = data else { completion(.failure(.decode)); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status >= 200 && status < 300 else {
                let msg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
                // Refresh token rejected (revoked / expired) — force sign-out so UI prompts re-auth.
                if status == 400 || status == 401 {
                    DispatchQueue.main.async { self.signOut() }
                }
                completion(.failure(.supabaseRejected(msg)))
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = json["access_token"] as? String,
                  let refresh = json["refresh_token"] as? String,
                  let expiresIn = json["expires_in"] as? Double else {
                completion(.failure(.decode))
                return
            }
            let newSession = AuthSession(
                accessToken: access,
                refreshToken: refresh,
                expiresAt: Date().addingTimeInterval(expiresIn),
                userId: session.userId
            )
            DispatchQueue.main.async {
                self.session = newSession
                self.keychain.writeSession(newSession)
                WatchConnectivityManager.shared.sendAuthSession(newSession)
                completion(.success(newSession))
            }
        }.resume()
    }

    // MARK: - Sign In With Apple

    /// Kicks off the native SIWA flow. Completion fires on main.
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
                self.exchangeWithSupabase(identityToken: identityToken) { exchangeResult in
                    DispatchQueue.main.async {
                        self.isSigningIn = false
                        if case .success(let session) = exchangeResult {
                            self.session = session
                            self.keychain.writeSession(session)
                            WatchConnectivityManager.shared.sendAuthSession(session)
                        }
                        completion(exchangeResult)
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
        keychain.deleteSession()
        session = nil
        WatchConnectivityManager.shared.sendAuthSession(nil)
    }

    // MARK: - Supabase token exchange

    private func exchangeWithSupabase(identityToken: String, completion: @escaping (Result<AuthSession, AuthError>) -> Void) {
        let payload: [String: Any] = [
            "provider": "apple",
            "id_token": identityToken
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let req = client.authedRequest(path: "/auth/v1/token?grant_type=id_token", method: "POST", body: body) else {
            completion(.failure(.network(NSError(domain: "AuthManager", code: -1))))
            return
        }

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error { completion(.failure(.network(error))); return }
            guard let data = data else { completion(.failure(.decode)); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status >= 200 && status < 300 else {
                let msg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
                completion(.failure(.supabaseRejected(msg)))
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = json["access_token"] as? String,
                  let refresh = json["refresh_token"] as? String,
                  let expiresIn = json["expires_in"] as? Double,
                  let user = json["user"] as? [String: Any],
                  let userId = user["id"] as? String else {
                completion(.failure(.decode))
                return
            }
            let session = AuthSession(
                accessToken: access,
                refreshToken: refresh,
                expiresAt: Date().addingTimeInterval(expiresIn),
                userId: userId
            )
            completion(.success(session))
        }.resume()
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

// MARK: - Keychain helper

private struct KeychainStore {
    let service: String
    private let account = "session"

    func readSession() -> AuthSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let session = try? JSONDecoder().decode(AuthSession.self, from: data) else {
            return nil
        }
        return session
    }

    func writeSession(_ session: AuthSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    func deleteSession() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
