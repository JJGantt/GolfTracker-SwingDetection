import Foundation
import Supabase

/// In-memory cache of historical first-stroke locations per hole on a
/// course. Loaded once at round start (one batched query that joins
/// `strokes` to `rounds` for `course_id`); read by `AutoAdvanceMonitor`
/// to fire Trigger C (user near a known prior first-stroke = playing
/// that hole now).
///
/// "First stroke" = `stroke_number == 1`. Cross-user, cross-round —
/// any prior round's first shot at this course is fair game. Penalty
/// strokes can't be the first stroke of a hole (you have to hit the
/// ball before getting a penalty), so no extra filter needed.
///
/// Not refreshed mid-round. Same freshness model as `HoleHeightCellCache`.
///
/// Reads need to work from `AutoAdvanceMonitor.evaluate` which runs on a
/// non-isolated Combine sink, so we use an NSLock instead of `@MainActor`
/// — the read path stays non-isolated and the write path locks during
/// the dictionary swap.
final class HistoricalFirstStrokeCache: @unchecked Sendable {
    static let shared = HistoricalFirstStrokeCache()

    /// Lat/lon of one prior first-stroke. Lean shape — the monitor only
    /// needs the coordinate to compute distance.
    struct FirstStroke {
        let latitude: Double
        let longitude: Double
    }

    /// Keyed by `(courseId, holeNumber)`. Empty entry = queried, none
    /// exist yet (first round on this hole). Missing entry = not loaded.
    private var byKey: [Key: [FirstStroke]] = [:]
    private let lock = NSLock()

    private struct Key: Hashable {
        let courseId: UUID
        let holeNumber: Int
    }

    /// Pull every first-stroke (`stroke_number = 1`) for any round whose
    /// `course_id` matches, across all users. PostgREST `select` with an
    /// embedded `rounds!inner` filter does the join in one query.
    func loadForCourse(courseId: UUID) async {
        let supabase = SupabaseManager.shared.client

        struct Row: Decodable {
            let hole_number: Int
            let latitude: Double
            let longitude: Double
        }

        do {
            // Paged. This grows one row per hole per round played here forever,
            // so it crosses PostgREST's 1000-row cap on its own eventually —
            // and an unbounded select would then start quietly forgetting the
            // oldest history rather than failing.
            var rows: [Row] = []
            var from = 0
            while true {
                let page: [Row] = try await supabase
                    .from("strokes")
                    .select("hole_number,latitude,longitude,rounds!inner(course_id)")
                    .eq("stroke_number", value: 1)
                    .eq("rounds.course_id", value: courseId.uuidString)
                    .order("id", ascending: true)
                    .range(from: from, to: from + ElevationFoldIn.readPageSize - 1)
                    .execute()
                    .value
                rows.append(contentsOf: page)
                if page.count < ElevationFoldIn.readPageSize { break }
                from += ElevationFoldIn.readPageSize
            }

            var grouped: [Key: [FirstStroke]] = [:]
            for r in rows {
                let key = Key(courseId: courseId, holeNumber: r.hole_number)
                grouped[key, default: []].append(
                    FirstStroke(latitude: r.latitude, longitude: r.longitude)
                )
            }
            lock.lock(); byKey = grouped; lock.unlock()

            ClientEventLogger.log("autoadvance.history.loaded", detail: [
                "courseId": .string(courseId.uuidString),
                "shotCount": .integer(rows.count),
                "holeCount": .integer(grouped.count)
            ])
        } catch {
            ClientEventLogger.log("autoadvance.history.load.failed", detail: [
                "courseId": .string(courseId.uuidString),
                "error": .string(String(describing: error).prefix(200).description)
            ])
        }
    }

    func firstStrokes(forCourseId courseId: UUID, holeNumber: Int) -> [FirstStroke] {
        lock.lock(); defer { lock.unlock() }
        return byKey[Key(courseId: courseId, holeNumber: holeNumber)] ?? []
    }

    func clear() {
        lock.lock(); byKey.removeAll(); lock.unlock()
    }
}
