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
