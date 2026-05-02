import Foundation
import Supabase

/// Lightweight fire-and-forget logger that writes to the `client_events`
/// table in Supabase. Used to diagnose UI/sync timing issues on watch
/// without needing console output — sprinkle `ClientEventLogger.log(...)`
/// at key transitions, then query the table afterward to see where time
/// was spent.
///
/// Intentionally non-blocking: every call dispatches a Task and returns.
/// The Task's HTTP insert is what costs time on the network, but never
/// the call site itself.
///
/// On platforms where this would still gate behavior (e.g. main thread
/// tight loops), prefer using it sparingly — it's an investigative tool,
/// not a permanent telemetry pipeline.
enum ClientEventLogger {
    /// Runtime toggle backed by UserDefaults. Default OFF — turn on via
    /// the iOS Settings → Developer section (long-press the Settings title
    /// to reveal). Toggling on iPhone syncs to the watch via
    /// WatchConnectivity. Off-mode is cheap: just a UserDefaults read +
    /// guard return; no Task spawn, no detail-dict evaluation.
    static let userDefaultsKey = "clientEventLoggerEnabled"

    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: userDefaultsKey)
    }

    /// Set the toggle locally and persist it to UserDefaults. iOS callers
    /// also forward to the watch via WatchConnectivity (handled at the
    /// settings UI layer, not here).
    static func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: userDefaultsKey)
    }

    /// Single device label set at compile time per target so we don't have
    /// to think about it at every call site.
    private static var deviceLabel: String {
        #if os(watchOS)
        return "watch"
        #else
        return "phone"
        #endif
    }

    /// Log an event with optional small JSON-encodable detail dict. Don't
    /// pass huge payloads — this hits the network on every call.
    static func log(_ event: String, detail: [String: AnyJSON]? = nil) {
        guard enabled else { return }
        let now = Date()
        Task.detached(priority: .background) {
            let userId = await currentUserId()
            guard let uid = userId else { return }
            struct Row: Encodable {
                let user_id: String
                let device: String
                let event: String
                let detail: AnyJSON?
                let occurred_at: String
            }
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let row = Row(
                user_id: uid,
                device: deviceLabel,
                event: event,
                detail: detail.map { AnyJSON.object($0) },
                occurred_at: isoFormatter.string(from: now)
            )
            do {
                try await SupabaseManager.shared.from("client_events").insert(row).execute()
            } catch {
                // Swallow — this is diagnostic; if it fails, we just don't
                // see the event later. Don't ever throw or block the caller.
            }
        }
    }

    @MainActor
    private static func currentUserId() async -> String? {
        #if os(watchOS)
        return WatchAuthSession.shared.currentUserId
        #else
        return AuthManager.shared.currentUserId
        #endif
    }
}
