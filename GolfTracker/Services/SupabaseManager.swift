import Foundation
import Supabase

/// Singleton holding the supabase-swift SDK client. Used by both iOS and
/// watchOS targets — the SDK supports both. Replaces the hand-rolled
/// `SupabaseClient`, `SupabaseSync`, and per-platform auth refresh logic.
///
/// One client per process. Auth state, session refresh, retry, and Realtime
/// connection lifecycle are all handled by the SDK internally.
final class SupabaseManager: Sendable {
    static let shared = SupabaseManager()

    let client: Supabase.SupabaseClient
    /// Project URL — exposed for callers that need to build URLs against
    /// Supabase services (e.g., Edge Function endpoints) without going through
    /// the SDK. The SDK's `client.supabaseURL` is internal-access.
    let projectURL: URL

    private init() {
        let url = URL(string: "https://oumnicnvayqrbfbljgyl.supabase.co")!
        let key = "sb_publishable_i0loB-AZw2qGokBJzHGSKA_VGgAgjBi"
        self.projectURL = url

        // Plumb the SDK's internal log messages into our ClientEventLogger
        // so we can see WebSocket connection failures, channel join errors,
        // auth refresh issues, etc. — all of which the SDK currently swallows.
        // Especially important on watchOS where `realtime.connect()` silently
        // fails and our only signal is the post-condition `.disconnected`
        // status; the SDK's error-level logs are the source of truth.
        let options = SupabaseClientOptions(
            global: .init(logger: ForwardingSupabaseLogger())
        )
        self.client = Supabase.SupabaseClient(supabaseURL: url, supabaseKey: key, options: options)
    }

    // Convenience accessors — same shape across both targets.
    var auth: AuthClient { client.auth }
    var storage: SupabaseStorageClient { client.storage }
    var realtime: RealtimeClientV2 { client.realtimeV2 }

    /// Postgrest query builder for a table. e.g. `manager.from("rounds").select()`
    func from(_ table: String) -> PostgrestQueryBuilder { client.from(table) }
}

// MARK: - SDK log forwarder

/// Forwards SDK-internal log messages (debug/warning/error) into our
/// ClientEventLogger pipeline. We only care about WARNING and ERROR for
/// remote logging — debug/verbose are too noisy. This is how we get
/// visibility into errors the SDK swallows internally (silent socket
/// connect failures, channel join rejections, auth refresh issues, etc.).
struct ForwardingSupabaseLogger: SupabaseLogger {
    func log(message: SupabaseLogMessage) {
        guard message.level == .warning || message.level == .error else { return }
        ClientEventLogger.log("sdk.\(message.level)", detail: [
            "system": .string(message.system),
            "message": .string(message.message),
            "fn": .string("\(message.function):\(message.line)")
        ])
        // Auto-recovery hook (watch only): if the SDK reports a 401-like
        // failure, ask the iPhone to re-send the current AuthSession via
        // WC. Common cause is a stale refresh token after the watch's been
        // offline; the iPhone usually has a fresh one. Throttled inside
        // WatchAuthSession so we don't spam on repeated errors.
        #if os(watchOS)
        let lower = message.message.lowercased()
        if lower.contains("401") || lower.contains("unauthorized") || lower.contains("jwt expired") {
            WatchAuthSession.shared.requestRefreshFromPhone()
        }
        #endif
    }
}

// MARK: - Bridge from SDK Session to our wire-format AuthSession

extension AuthSession {
    /// Build our wire-format session from the SDK's Session type. Used by both
    /// AuthManager (iPhone) and WatchAuthSession to mirror the SDK's session
    /// into a Codable struct that can travel over WatchConnectivity.
    init(_ s: Supabase.Session) {
        self.init(
            accessToken: s.accessToken,
            refreshToken: s.refreshToken,
            expiresAt: Date(timeIntervalSince1970: s.expiresAt),
            userId: s.user.id.uuidString
        )
    }
}
