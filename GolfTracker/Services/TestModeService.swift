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
    private var started = false

    private init() {}

    // MARK: - Lifecycle

    /// Wire this once at app launch (after auth is available). Pulls the
    /// initial DB state, then subscribes to changes.
    func start() {
        guard !started else { return }
        started = true
        Task { await self.bootstrap() }
    }

    private func bootstrap() async {
        guard currentUserId() != nil else {
            // Not signed in yet — try again later. Auth handlers can call
            // start() once a session is available.
            started = false
            return
        }
        await refreshFromDB()
        await subscribeToChanges()
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
            if let row = rows.first {
                applyState(enabled: row.enabled, lat: row.simulated_lat, lon: row.simulated_lon)
            }
        } catch {
            dprint("🧪 [TestModeService] refresh failed: \(error.localizedDescription)")
        }
    }

    private func subscribeToChanges() async {
        guard let uid = currentUserId() else { return }
        let ch = supabase.realtime.channel("user_test_state:\(uid)")
        channel = ch
        let pgFilter: RealtimePostgresFilter = .eq("user_id", value: uid)
        let stream = ch.postgresChange(AnyAction.self, table: "user_test_state", filter: pgFilter)
        subscription = Task { [weak self] in
            for await action in stream {
                await self?.handleChange(action)
            }
        }
        do {
            try await ch.subscribeWithError()
        } catch {
            dprint("🧪 [TestModeService] subscribe failed: \(error.localizedDescription)")
        }
    }

    private func handleChange(_ action: AnyAction) async {
        let record: [String: AnyJSON]
        switch action {
        case .insert(let a): record = a.record
        case .update(let a): record = a.record
        case .delete:
            applyState(enabled: false, lat: nil, lon: nil)
            return
        }
        let enabled = (record["enabled"]?.boolValue) ?? false
        let lat = record["simulated_lat"]?.doubleValue
        let lon = record["simulated_lon"]?.doubleValue
        applyState(enabled: enabled, lat: lat, lon: lon)
    }

    private func applyState(enabled: Bool, lat: Double?, lon: Double?) {
        self.enabled = enabled
        if let lat = lat, let lon = lon {
            simulatedCoord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        } else {
            simulatedCoord = nil
        }
        // Push into LocationManager. Order matters: enable test mode
        // first so the apply call actually publishes; or disable to fall
        // back to real GPS.
        if enabled {
            LocationManager.shared.setTestModeEnabled(true)
            if let coord = simulatedCoord {
                LocationManager.shared.applyTestLocation(coord)
            }
        } else {
            LocationManager.shared.setTestModeEnabled(false)
        }
    }

    // MARK: - Writes (called from iPhone TestModeView)

    /// Toggle test mode on/off in the DB. Echoes back through Realtime to
    /// update both this device and any other device the same user is on.
    func setEnabled(_ enabled: Bool) async {
        guard let uid = currentUserId() else { return }
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
