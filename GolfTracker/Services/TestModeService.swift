import Foundation
import CoreLocation
import Supabase

/// Cross-device location simulation. Both targets run this — phone uses it
/// to write the user's chosen simulated coord into Supabase, watch (and
/// phone itself) subscribe via Realtime postgres-changes and feed the
/// coord into `LocationManager` so all downstream consumers (round
/// resolver, distance display, auto-advance, map markers) react as if
/// it were a real GPS update.
///
/// State lives in the `user_test_state` table — one row per user, RLS
/// scoped so each user only sees / writes their own. Migration 00022.
@MainActor
final class TestModeService: ObservableObject {
    static let shared = TestModeService()

    /// Local mirror of the DB state. Reads update both this and the
    /// LocationManager when a row arrives via Realtime; writes (from the
    /// developer view) push to DB and let the echo come back through.
    @Published private(set) var enabled: Bool = false
    @Published private(set) var simulatedCoord: CLLocationCoordinate2D?

    private let supabase = SupabaseManager.shared
    private var channel: RealtimeChannelV2?
    private var subscription: Task<Void, Never>?
    /// Single-flight guard for `start()`. Holding a non-nil Task means
    /// bootstrap is in flight or has completed; concurrent callers will
    /// reuse that Task instead of racing into duplicate channels (which
    /// previously caused Swift.CancellationError on the watch when both
    /// GolfWatchApp.init and WatchAuthSession.onSessionChanged fired
    /// simultaneously).
    private var bootstrapTask: Task<Void, Never>?
    /// One-time observer of the Realtime socket's status stream. Logs every
    /// transition so we can correlate watch-side socket teardowns with the
    /// underlying cause (backgrounding, network loss, server close, etc.).
    private var socketStatusTask: Task<Void, Never>?

    private init() {}

    // MARK: - Lifecycle

    /// Wire this at app launch and again when auth becomes available
    /// (auth might not be ready at first launch, especially on the watch
    /// where the session arrives via WatchConnectivity from the phone).
    /// Idempotent — only runs the bootstrap Task once.
    func start() {
        // Already bootstrapped + still has a live channel — nothing to do.
        if let existing = bootstrapTask, channel != nil {
            _ = existing
            return
        }
        // Currently bootstrapping — let the in-flight Task finish; don't
        // start a second one.
        if bootstrapTask != nil, channel == nil {
            return
        }
        // Either never started, or the previous attempt completed without
        // a live channel (e.g., auth wasn't ready) — start fresh.
        bootstrapTask = Task { [weak self] in
            await self?.bootstrap()
        }
    }

    private func bootstrap() async {
        ClientEventLogger.log("testmode.bootstrap.enter", detail: [
            "hasChannel": .bool(channel != nil),
            "hasUid": .bool(currentUserId() != nil)
        ])
        guard currentUserId() != nil else {
            ClientEventLogger.log("testmode.bootstrap.bail.noAuth")
            // Clear bootstrapTask so a future start() (after auth arrives)
            // can retry. Otherwise the never-completed bootstrap blocks
            // future attempts.
            bootstrapTask = nil
            return
        }
        await refreshFromDB()
        // The Realtime path doesn't work on the watch — non-LTE watches
        // can't open WebSockets through the Bluetooth phone tether (see
        // docs/MULTIPLAYER.md). On the phone the Realtime subscription is
        // valuable for cross-device test-mode + dev visibility; on the
        // watch we get all our updates over WatchConnectivity from the
        // phone (see TestModeService.applyState's WC mirror call) and the
        // initial state from refreshFromDB() above.
        #if os(iOS)
        await subscribeToChanges()
        #endif
        ClientEventLogger.log("testmode.bootstrap.done")
    }

    private func refreshFromDB() async {
        do {
            struct Row: Decodable {
                let user_id: String
                let enabled: Bool
                let simulated_lat: Double?
                let simulated_lon: Double?
            }
            guard let uid = currentUserId() else { return }
            let rows: [Row] = try await supabase.from("user_test_state")
                .select()
                .eq("user_id", value: uid)
                .limit(1)
                .execute()
                .value
            ClientEventLogger.log("testmode.refresh.fetched", detail: [
                "rowCount": .integer(rows.count),
                "enabled": rows.first.map { .bool($0.enabled) } ?? .null,
                "lat": rows.first?.simulated_lat.map { .double($0) } ?? .null,
                "lon": rows.first?.simulated_lon.map { .double($0) } ?? .null
            ])
            if let row = rows.first {
                applyState(enabled: row.enabled, lat: row.simulated_lat, lon: row.simulated_lon)
            }
        } catch {
            ClientEventLogger.log("testmode.refresh.failed", detail: [
                "error": .string(error.localizedDescription)
            ])
        }
    }

    private func startSocketStatusObserver() {
        // Idempotent — only spawn one observer per process.
        if socketStatusTask != nil { return }
        let stream = supabase.realtime.statusChange
        socketStatusTask = Task {
            for await status in stream {
                ClientEventLogger.log("testmode.socket.status", detail: [
                    "status": .string("\(status)")
                ])
            }
        }
    }

    private func subscribeToChanges() async {
        guard let uid = currentUserId() else { return }

        // Tap the realtime client's status stream once so we observe socket
        // state transitions for ongoing diagnostics (especially after
        // backgrounding, OS-induced socket teardown, etc).
        startSocketStatusObserver()

        // Never call `supabase.realtime.connect()` here. On a socket that is
        // already open (RealtimeSync's channel usually opens it moments
        // earlier), supabase-swift 2.45 re-runs its connected handler, which
        // drops the message listener: every frame — join replies, heartbeats,
        // postgres changes — goes nowhere until the heartbeat times out ~52s
        // later. That was behind every first-attempt "Maximum retry attempts
        // reached" subscribe failure since August. The channel subscribe
        // connects the socket itself; if the socket is not up yet, the
        // attempt fails and `subscribePersistently` retries it a second later.

        let ch = supabase.realtime.channel("user_test_state:\(uid)")
        channel = ch
        let pgFilter: RealtimePostgresFilter = .eq("user_id", value: uid)
        let stream = ch.postgresChange(AnyAction.self, table: "user_test_state", filter: pgFilter)
        subscription = Task { [weak self] in
            ClientEventLogger.log("testmode.subscribe.streamLoop.enter")
            for await action in stream {
                ClientEventLogger.log("testmode.subscribe.streamLoop.gotEvent")
                await self?.handleChange(action)
            }
            ClientEventLogger.log("testmode.subscribe.streamLoop.exit")
        }
        // Persistent subscribe with retry/backoff. The bare
        // `subscribeWithError` call routinely failed on watchOS with
        // Swift.CancellationError when the WebSocket got killed by the OS
        // backgrounding the app — and without a retry loop, the watch sat
        // there with a dead subscription forever. RealtimeReconnect handles
        // that: retries with exponential backoff (1s → 30s cap), watches
        // statusChange and re-subscribes when the channel state leaves
        // .subscribed, exits cleanly when the parent task is cancelled.
        await ch.subscribePersistently(label: "testmode")
    }

    private func handleChange(_ action: AnyAction) async {
        let record: [String: AnyJSON]
        switch action {
        case .insert(let a): record = a.record
        case .update(let a): record = a.record
        case .delete:
            ClientEventLogger.log("testmode.realtime.delete")
            applyState(enabled: false, lat: nil, lon: nil)
            return
        }
        let enabled = (record["enabled"]?.boolValue) ?? false
        let lat = record["simulated_lat"]?.doubleValue
        let lon = record["simulated_lon"]?.doubleValue
        ClientEventLogger.log("testmode.realtime.change", detail: [
            "enabled": .bool(enabled),
            "lat": lat.map { .double($0) } ?? .null,
            "lon": lon.map { .double($0) } ?? .null
        ])
        applyState(enabled: enabled, lat: lat, lon: lon)
    }

    private func applyState(enabled: Bool, lat: Double?, lon: Double?) {
        ClientEventLogger.log("testmode.applyState", detail: [
            "enabled": .bool(enabled),
            "lat": lat.map { .double($0) } ?? .null,
            "lon": lon.map { .double($0) } ?? .null
        ])
        self.enabled = enabled
        if let lat = lat, let lon = lon {
            simulatedCoord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        } else {
            simulatedCoord = nil
        }
        // Push into LocationManager. Order: stash the simulated coord
        // first so setTestModeEnabled's forcedTestLocation read picks it
        // up, then enable. Both calls are synchronous so by the time we
        // return, isTestModeEnabled is true and location is the simulated
        // coord — no race against startTracking() being called elsewhere.
        if enabled {
            if let coord = simulatedCoord {
                LocationManager.shared.applyTestLocation(coord)
            }
            LocationManager.shared.setTestModeEnabled(true)
        } else {
            LocationManager.shared.setTestModeEnabled(false)
        }
        // Mirror to the watch via WatchConnectivity. The Realtime path on
        // the watch can't deliver this (non-LTE watches can't open
        // WebSockets — see docs/MULTIPLAYER.md), so the phone is the
        // authoritative push channel for test-mode location during dev.
        #if os(iOS)
        WatchConnectivityManager.shared.sendTestModeState(
            enabled: enabled, lat: lat, lon: lon
        )
        #endif
    }

    /// Entry point invoked by `WatchConnectivityManager` when a test-mode
    /// state payload arrives from the phone. Re-uses the same applyState
    /// pipeline as the (defunct on watch) Realtime path.
    func applyFromWatchConnectivity(enabled: Bool, lat: Double?, lon: Double?) {
        ClientEventLogger.log("testmode.wc.received", detail: [
            "enabled": .bool(enabled),
            "lat": lat.map { .double($0) } ?? .null,
            "lon": lon.map { .double($0) } ?? .null
        ])
        applyState(enabled: enabled, lat: lat, lon: lon)
    }

    // MARK: - Writes (called from iPhone TestModeView)

    /// Toggle test mode on/off in the DB. Echoes back through Realtime to
    /// update both this device and any other device the same user is on.
    func setEnabled(_ enabled: Bool) async {
        guard let uid = currentUserId() else { return }
        // Apply local state immediately so the UI reflects the toggle the
        // moment the user taps. Without this, the toggle just sits there
        // until the Realtime echo round-trips from Supabase (1-3s in good
        // conditions, longer if the WebSocket is flaky), making it look
        // like clicking did nothing. The Realtime echo arrives later and
        // applies the same state — a harmless no-op.
        await MainActor.run {
            applyState(enabled: enabled, lat: simulatedCoord?.latitude, lon: simulatedCoord?.longitude)
        }
        struct Row: Encodable {
            let user_id: String
            let enabled: Bool
            let simulated_lat: Double?
            let simulated_lon: Double?
            let updated_at: String
        }
        let row = Row(
            user_id: uid,
            enabled: enabled,
            simulated_lat: simulatedCoord?.latitude,
            simulated_lon: simulatedCoord?.longitude,
            updated_at: ISO8601DateFormatter().string(from: Date())
        )
        do {
            try await supabase.from("user_test_state")
                .upsert(row, onConflict: "user_id")
                .execute()
        } catch {
            dprint("🧪 [TestModeService] setEnabled failed: \(error.localizedDescription)")
        }
    }

    /// Update the simulated coord. If test mode is currently off, also
    /// flips it on as a convenience — tapping the map should "just work."
    func setSimulatedCoord(_ coord: CLLocationCoordinate2D) async {
        guard let uid = currentUserId() else { return }
        // Optimistic local apply — see setEnabled comment for rationale.
        await MainActor.run {
            applyState(enabled: true, lat: coord.latitude, lon: coord.longitude)
        }
        struct Row: Encodable {
            let user_id: String
            let enabled: Bool
            let simulated_lat: Double
            let simulated_lon: Double
            let updated_at: String
        }
        let row = Row(
            user_id: uid,
            enabled: true,
            simulated_lat: coord.latitude,
            simulated_lon: coord.longitude,
            updated_at: ISO8601DateFormatter().string(from: Date())
        )
        do {
            try await supabase.from("user_test_state")
                .upsert(row, onConflict: "user_id")
                .execute()
        } catch {
            dprint("🧪 [TestModeService] setSimulatedCoord failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func currentUserId() -> String? {
        #if os(watchOS)
        return WatchAuthSession.shared.currentUserId
        #else
        return AuthManager.shared.currentUserId
        #endif
    }
}
