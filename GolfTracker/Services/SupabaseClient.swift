import Foundation

/// Lightweight REST client for Supabase. Shared between Auth + data sync.
/// Matches the pattern of `SupabaseUploader` on the Watch — no SDK dependency.
final class SupabaseClient {
    static let shared = SupabaseClient()

    let projectURL = "https://oumnicnvayqrbfbljgyl.supabase.co"
    let anonKey = "sb_publishable_i0loB-AZw2qGokBJzHGSKA_VGgAgjBi"

    private init() {}

    /// Build a request with the anon key on `apikey` and whatever the current
    /// session access token (if any) on `Authorization`. Falls back to anon
    /// key on both when there's no session.
    func authedRequest(path: String, method: String = "GET", body: Data? = nil, accessToken: String? = nil) -> URLRequest? {
        guard let url = URL(string: "\(projectURL)\(path)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(accessToken ?? anonKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return req
    }
}
