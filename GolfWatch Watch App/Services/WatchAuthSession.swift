import Foundation

/// Holds the Watch's mirror of the Supabase auth session, forwarded from the
/// iPhone via WatchConnectivity. Refreshes the access token directly against
/// Supabase when it nears expiry so uploads keep working even when the iPhone
/// is unreachable.
final class WatchAuthSession {
    static let shared = WatchAuthSession()

    private let projectURL = "https://oumnicnvayqrbfbljgyl.supabase.co"
    private let anonKey = "sb_publishable_i0loB-AZw2qGokBJzHGSKA_VGgAgjBi"
    private let keychain = KeychainStore(service: "com.Jared.GolfTracker.watch.auth")
    private let queue = DispatchQueue(label: "watch-auth-session")
    private var refreshInFlight: [(Result<String, Error>) -> Void] = []
    private var isRefreshing = false

    private(set) var session: AuthSession?

    /// Notified whenever the session changes (sign-in, refresh, sign-out).
    /// SupabaseUploader subscribes to flush its pending queue when a session arrives.
    var onSessionChanged: ((AuthSession?) -> Void)?

    private init() {
        self.session = keychain.read()
    }

    var isSignedIn: Bool { session != nil }
    var currentUserId: String? { session?.userId }

    /// Replace the stored session (called when iPhone forwards a new one or signs out).
    func apply(_ session: AuthSession?) {
        queue.async {
            self.session = session
            if let session = session {
                self.keychain.write(session)
            } else {
                self.keychain.delete()
            }
            DispatchQueue.main.async {
                self.onSessionChanged?(session)
            }
        }
    }

    /// Returns a non-expired access token. Refreshes if within 5 minutes of expiry.
    /// Coalesces concurrent refresh calls so we don't fire multiple refreshes in parallel.
    func validAccessToken(completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            guard let session = self.session else {
                completion(.failure(WatchAuthError.notSignedIn))
                return
            }
            if session.expiresAt.timeIntervalSinceNow > 300 {
                completion(.success(session.accessToken))
                return
            }
            self.refreshInFlight.append(completion)
            if self.isRefreshing { return }
            self.isRefreshing = true
            self.performRefresh(refreshToken: session.refreshToken, userId: session.userId)
        }
    }

    /// Force a refresh (used after a 401 retry path).
    func forceRefresh(completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            guard let session = self.session else {
                completion(.failure(WatchAuthError.notSignedIn))
                return
            }
            self.refreshInFlight.append(completion)
            if self.isRefreshing { return }
            self.isRefreshing = true
            self.performRefresh(refreshToken: session.refreshToken, userId: session.userId)
        }
    }

    private func performRefresh(refreshToken: String, userId: String) {
        let payload = ["refresh_token": refreshToken]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let url = URL(string: "\(projectURL)/auth/v1/token?grant_type=refresh_token") else {
            finishRefresh(.failure(WatchAuthError.badRequest))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            self.queue.async {
                if let error = error {
                    self.finishRefresh(.failure(error))
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status >= 200 && status < 300,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let access = json["access_token"] as? String,
                      let refresh = json["refresh_token"] as? String,
                      let expiresIn = json["expires_in"] as? Double else {
                    // Refresh token revoked — clear local session, iPhone will need to re-push
                    if status == 400 || status == 401 {
                        self.session = nil
                        self.keychain.delete()
                        DispatchQueue.main.async { self.onSessionChanged?(nil) }
                    }
                    self.finishRefresh(.failure(WatchAuthError.refreshFailed(status)))
                    return
                }
                let newSession = AuthSession(
                    accessToken: access,
                    refreshToken: refresh,
                    expiresAt: Date().addingTimeInterval(expiresIn),
                    userId: userId
                )
                self.session = newSession
                self.keychain.write(newSession)
                DispatchQueue.main.async { self.onSessionChanged?(newSession) }
                self.finishRefresh(.success(access))
            }
        }.resume()
    }

    private func finishRefresh(_ result: Result<String, Error>) {
        let callbacks = refreshInFlight
        refreshInFlight.removeAll()
        isRefreshing = false
        for cb in callbacks { cb(result) }
    }
}

enum WatchAuthError: Error {
    case notSignedIn
    case badRequest
    case refreshFailed(Int)
}

private struct KeychainStore {
    let service: String
    private let account = "session"

    func read() -> AuthSession? {
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

    func write(_ session: AuthSession) {
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

    func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
