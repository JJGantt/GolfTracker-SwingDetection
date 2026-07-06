import Foundation
import CoreLocation
import Supabase

/// In-memory cache of path samples per `(round_id, hole_number)`,
/// pulled on demand from `round_altitude_readings`. Drives the iPhone's
/// breadcrumb display when reviewing any hole — current hole during a
/// live round (data refreshed on hole change; up-to-30s stale matches
/// the watch's flush cadence), prior holes during a live round, or
/// post-round.
///
/// The same code path serves all three cases because the DB is the
/// source of truth either way. Live updates aren't subscribed to today
/// — refresh-on-hole-change is sufficient for a "pick up the phone and
/// glance" workflow. Add Realtime subscription on
/// `round_altitude_readings` later if continuous tailing becomes useful.
@MainActor
final class RoundPathCache: ObservableObject {
    static let shared = RoundPathCache()

    /// One row's worth of breadcrumb data — only the fields the
    /// renderer needs.
    struct Sample: Identifiable {
        let id = UUID()
        let coordinate: CLLocationCoordinate2D
        let recordedAt: Date
    }

    /// Published so views observing the cache re-render automatically
    /// when the active key's data lands. Keyed by hole number for the
    /// active round id (set via `loadIfNeeded`); the cache holds prior
    /// keys too so back-nav between holes doesn't refetch.
    @Published private(set) var samplesByKey: [Key: [Sample]] = [:]

    struct Key: Hashable {
        let roundId: UUID
        let holeNumber: Int
    }

    /// Pull path samples for `(roundId, holeNumber)` if not already
    /// cached, or refresh them. Idempotent — safe to call from
    /// `onAppear` and `onChange(of: currentHoleIndex)` without
    /// debouncing.
    func loadIfNeeded(roundId: UUID, holeNumber: Int, forceRefresh: Bool = false) {
        let key = Key(roundId: roundId, holeNumber: holeNumber)
        if !forceRefresh, samplesByKey[key] != nil { return }
        Task { await load(key: key) }
    }

    /// Drop everything for a round. Call when the user navigates away
    /// from a round so the cache doesn't grow unbounded across many
    /// rounds in a single session.
    func clear(roundId: UUID) {
        samplesByKey = samplesByKey.filter { $0.key.roundId != roundId }
    }

    func clearAll() {
        samplesByKey.removeAll()
    }

    func samples(forRoundId roundId: UUID, holeNumber: Int) -> [Sample] {
        samplesByKey[Key(roundId: roundId, holeNumber: holeNumber)] ?? []
    }

    // MARK: - Private

    private func load(key: Key) async {
        struct Row: Decodable {
            let lat: Double
            let lon: Double
            let recorded_at: String
        }

        let isoFormatter: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        let isoFormatterNoFrac = ISO8601DateFormatter()

        do {
            let rows: [Row] = try await SupabaseManager.shared.client
                .from("round_altitude_readings")
                .select("lat,lon,recorded_at")
                .eq("round_id", value: key.roundId.uuidString)
                .eq("hole_number", value: key.holeNumber)
                .order("recorded_at", ascending: true)
                .execute()
                .value

            let samples: [Sample] = rows.compactMap { r in
                let date = isoFormatter.date(from: r.recorded_at)
                    ?? isoFormatterNoFrac.date(from: r.recorded_at)
                    ?? Date()
                return Sample(
                    coordinate: CLLocationCoordinate2D(latitude: r.lat, longitude: r.lon),
                    recordedAt: date
                )
            }
            samplesByKey[key] = samples

            ClientEventLogger.log("roundpath.loaded", detail: [
                "roundId": .string(key.roundId.uuidString),
                "holeNumber": .integer(key.holeNumber),
                "count": .integer(samples.count)
            ])
        } catch {
            ClientEventLogger.log("roundpath.load.failed", detail: [
                "roundId": .string(key.roundId.uuidString),
                "holeNumber": .integer(key.holeNumber),
                "error": .string(String(describing: error).prefix(200).description)
            ])
        }
    }
}

// MARK: - Ghost round (historical hole overlay)

/// "Ghost round" overlay data: the user's most recent COMPLETED,
/// non-test round at the same course, rendered under the live map as a
/// dim dotted path plus dimmed grey stroke markers. Toggled from watch
/// Options / iOS floating buttons; the preference persists in
/// UserDefaults so it follows across holes and rounds.
///
/// Self-contained per-hole lazy fetch: views call
/// `loadIfNeeded(courseId:excludingRoundId:holeNumber:)` from appear /
/// hole-change / toggle-change. The store resolves the ghost round once
/// per (course, active-round) pair and caches per-hole path + strokes
/// for the session.
@MainActor
final class GhostRoundStore: ObservableObject {
    static let shared = GhostRoundStore()

    private static let enabledKey = "ghostRoundOverlayEnabled"

    @Published var enabled: Bool = UserDefaults.standard.bool(forKey: GhostRoundStore.enabledKey) {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            // Toggling ON mid-hole needs a data kick for the hole already
            // on screen — appear/hole-change triggers won't re-fire. The
            // last requested key is remembered even while disabled.
            if enabled, let r = lastRequest {
                loadIfNeeded(courseId: r.courseId, excludingRoundId: r.roundId, holeNumber: r.hole)
            }
        }
    }

    private var lastRequest: (courseId: UUID, roundId: UUID, hole: Int)?

    struct GhostStroke: Identifiable {
        let id = UUID()
        let coordinate: CLLocationCoordinate2D
        let strokeNumber: Int
    }

    @Published private(set) var pathByHole: [Int: [CLLocationCoordinate2D]] = [:]
    @Published private(set) var strokesByHole: [Int: [GhostStroke]] = [:]

    private var ghostRoundId: UUID?
    private var resolvedCourseId: UUID?
    private var resolvedExcludingRoundId: UUID?
    private var resolveInFlight = false
    private var holesLoading: Set<Int> = []

    /// Entry point for views. Resolves the ghost round for this course
    /// (once) and lazily fetches the given hole's path + strokes.
    /// Idempotent and cheap when already loaded — safe from onAppear,
    /// hole-change, and toggle-change without debouncing.
    func loadIfNeeded(courseId: UUID, excludingRoundId: UUID, holeNumber: Int) {
        lastRequest = (courseId, excludingRoundId, holeNumber)
        guard enabled else { return }
        if resolvedCourseId != courseId || resolvedExcludingRoundId != excludingRoundId {
            ghostRoundId = nil
            resolvedCourseId = courseId
            resolvedExcludingRoundId = excludingRoundId
            pathByHole = [:]
            strokesByHole = [:]
            holesLoading = []
        }
        if let ghost = ghostRoundId {
            fetchHoleIfNeeded(ghostRoundId: ghost, holeNumber: holeNumber)
            return
        }
        guard !resolveInFlight else { return }
        resolveInFlight = true
        Task {
            await resolveGhostRound(courseId: courseId, excludingRoundId: excludingRoundId)
            self.resolveInFlight = false
            if let ghost = self.ghostRoundId {
                self.fetchHoleIfNeeded(ghostRoundId: ghost, holeNumber: holeNumber)
            }
        }
    }

    /// Most recent ended round at the course by this user, excluding the
    /// active round and any test-mode rounds. Nil result (first-ever
    /// round at a course) just leaves the overlay empty.
    private func resolveGhostRound(courseId: UUID, excludingRoundId: UUID) async {
        struct Row: Decodable {
            let id: UUID
            let location_test_mode_enabled: Bool?
        }
        guard let userId = Self.currentUserId() else { return }
        do {
            let rows: [Row] = try await SupabaseManager.shared.client
                .from("rounds")
                .select("id,location_test_mode_enabled")
                .eq("course_id", value: courseId.uuidString)
                .eq("user_id", value: userId)
                .neq("id", value: excludingRoundId.uuidString)
                .not("ended_at", operator: .is, value: AnyJSON.null)
                .order("date", ascending: false)
                .limit(5)
                .execute()
                .value
            ghostRoundId = rows.first { $0.location_test_mode_enabled != true }?.id
            ClientEventLogger.log("ghostround.resolved", detail: [
                "courseId": .string(courseId.uuidString),
                "ghostRoundId": .string(ghostRoundId?.uuidString ?? "none")
            ])
        } catch {
            ClientEventLogger.log("ghostround.resolve.failed", detail: [
                "error": .string(String(describing: error).prefix(200).description)
            ])
        }
    }

    private func fetchHoleIfNeeded(ghostRoundId: UUID, holeNumber: Int) {
        guard pathByHole[holeNumber] == nil, !holesLoading.contains(holeNumber) else { return }
        holesLoading.insert(holeNumber)
        Task {
            await fetchHole(ghostRoundId: ghostRoundId, holeNumber: holeNumber)
            self.holesLoading.remove(holeNumber)
        }
    }

    private func fetchHole(ghostRoundId: UUID, holeNumber: Int) async {
        struct PathRow: Decodable { let lat: Double; let lon: Double }
        struct StrokeRow: Decodable {
            let latitude: Double
            let longitude: Double
            let stroke_number: Int
        }
        do {
            let pathRows: [PathRow] = try await SupabaseManager.shared.client
                .from("round_altitude_readings")
                .select("lat,lon")
                .eq("round_id", value: ghostRoundId.uuidString)
                .eq("hole_number", value: holeNumber)
                .order("recorded_at", ascending: true)
                .execute()
                .value
            let strokeRows: [StrokeRow] = try await SupabaseManager.shared.client
                .from("strokes")
                .select("latitude,longitude,stroke_number")
                .eq("round_id", value: ghostRoundId.uuidString)
                .eq("hole_number", value: holeNumber)
                .eq("is_penalty", value: false)
                .order("stroke_number", ascending: true)
                .execute()
                .value
            pathByHole[holeNumber] = pathRows.map {
                CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
            }
            strokesByHole[holeNumber] = strokeRows.map {
                GhostStroke(
                    coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude),
                    strokeNumber: $0.stroke_number
                )
            }
        } catch {
            // Leave the hole absent — a later loadIfNeeded retries.
            ClientEventLogger.log("ghostround.hole.failed", detail: [
                "holeNumber": .integer(holeNumber),
                "error": .string(String(describing: error).prefix(200).description)
            ])
        }
    }

    private static func currentUserId() -> String? {
        #if os(watchOS)
        return WatchAuthSession.shared.currentUserId
        #else
        return AuthManager.shared.currentUserId
        #endif
    }
}
