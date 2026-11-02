import Foundation
import Supabase

/// Retry/backoff wrapper for `RealtimeChannelV2` subscriptions.
///
/// Why this exists: the supabase-swift SDK's `subscribeWithError()` is
/// one-shot — it throws on the first failure (commonly `Swift.CancellationError`
/// on watchOS when the socket is racing or the WebSocket gets killed by the
/// OS) and provides no built-in retry, no auto-reconnect, no foreground
/// re-tickle. Mature WebSocket SDKs (Pusher, Ably, Firebase) all ship that
/// behavior by default. We fill the gap here.
///
/// Lifecycle: caller spawns a Task, calls `channel.subscribePersistently(...)`,
/// and lets it run until the Task is cancelled (round end, sign-out, etc.).
/// Inside, it loops:
///
///   1. `try await subscribeWithError()` with the channel.
///   2. On success: await the `statusChange` stream. While status stays
///      `.subscribed`, sit idle. When status flips to `.unsubscribed` or
///      `.errored` (socket died, server closed channel, etc.), break out
///      and re-subscribe.
///   3. On failure: log, sleep with exponential backoff (1s → 2s → 4s →
///      8s → 16s → 30s cap), retry. Backoff resets to 1s after a successful
///      subscribe.
///   4. On `Task.isCancelled`: log and exit cleanly.
///
/// The same channel object is reused across retries — supabase-swift handles
/// the underlying state transitions. Callers register `postgresChange` /
/// `broadcast` / `presenceChange` streams on the channel ONCE before calling
/// this; those streams live as long as the channel does and survive
/// re-subscribes.
extension RealtimeChannelV2 {
    /// Subscribe with retry/backoff. Returns when the parent Task is
    /// cancelled. Logs every state transition under the given label.
    ///
    /// - Parameter label: Logging tag for this subscription. Used as the
    ///   prefix on `ClientEventLogger` events: `<label>.subscribe.attempt`,
    ///   `.subscribe.ok`, `.subscribe.lost`, `.subscribe.failed`,
    ///   `.subscribe.cancelled`.
    func subscribePersistently(label: String, onSubscribed: (@Sendable () async -> Void)? = nil) async {
        var backoff: TimeInterval = 1.0
        let maxBackoff: TimeInterval = 30.0

        while !Task.isCancelled {
            ClientEventLogger.log("\(label).subscribe.attempt")
            do {
                try await self.subscribeWithError()
                ClientEventLogger.log("\(label).subscribe.ok")
                backoff = 1.0  // reset on success
                // Fire after every successful (re-)subscribe — this is the
                // catch-up hook for live-only postgres-changes that didn't
                // replay across the gap. Caller provides the reconcile work.
                if let onSubscribed = onSubscribed { await onSubscribed() }

                // Sit idle on the statusChange stream until the channel
                // leaves the .subscribed state. supabase-swift emits status
                // changes through this AsyncStream; iterating it parks the
                // Task cheaply (no polling). When the socket is torn down
                // by the OS (watchOS background, network change, server
                // close), status flips and we fall through to re-subscribe.
                for await status in self.statusChange {
                    if status == .subscribed { continue }
                    ClientEventLogger.log("\(label).subscribe.lost", detail: [
                        "status": .string("\(status)")
                    ])
                    break
                }
                // Either the stream ended or status is no longer .subscribed.
                // Loop and re-subscribe.
            } catch {
                if Task.isCancelled { break }
                ClientEventLogger.log("\(label).subscribe.failed", detail: [
                    "error": .string("\(error)"),
                    "backoffSec": .double(backoff)
                ])
                let sleepNs = UInt64(backoff * 1_000_000_000)
                try? await Task.sleep(nanoseconds: sleepNs)
                backoff = min(backoff * 2, maxBackoff)
            }
        }

        ClientEventLogger.log("\(label).subscribe.cancelled")
    }
}
