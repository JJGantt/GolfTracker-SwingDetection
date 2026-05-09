import Foundation
import Supabase

/// In-memory cache of `hole_height_cells` rows for a round's course.
/// Loaded once at round start (one batched query for all holes on the
/// course); read by `ElevationReadout` on every path-sample tick.
///
/// Not refreshed mid-round. Other users' rounds folding in during our
/// round won't appear in our cache until our next round, which is the
/// acceptable freshness penalty for keeping the read path fast and
/// network-free during play.
///
/// `@MainActor` so all access is serialized through the main actor —
/// no need for an NSLock. The network fetch is `await`-ed off-actor;
/// only the dictionary mutation stays on-actor.
@MainActor
final class HoleHeightCellCache {
    static let shared = HoleHeightCellCache()

    /// Keyed by `hole_key` (= "<courseId>:<holeNumber>"). Empty entry
    /// means "queried, no cells exist yet" (first round on this hole)
    /// — distinct from "missing key" (haven't loaded for this course).
    private var cellsByHoleKey: [String: [ElevationFoldIn.ExistingCell]] = [:]

    /// Load cells for every hole in `holeNumbers` on the given course.
    /// Single batched query — `select ... where hole_key in (...)`. Safe
    /// to call multiple times; replaces prior cache contents.
    func loadForCourse(courseId: UUID, holeNumbers: [Int]) async {
        guard !holeNumbers.isEmpty else {
            cellsByHoleKey.removeAll()
            return
        }
        let keys = holeNumbers.map { ElevationFoldIn.holeKey(courseId: courseId, holeNumber: $0) }
        let supabase = SupabaseManager.shared.client

        struct Row: Decodable {
            let hole_key: String
            let cell_lat: Double
            let cell_lon: Double
            let mean_alt_m: Double
            let n_samples: Int
        }

        do {
            let rows: [Row] = try await supabase
                .from("hole_height_cells")
                .select("hole_key,cell_lat,cell_lon,mean_alt_m,n_samples")
                .in("hole_key", values: keys)
                .execute()
                .value

            var grouped: [String: [ElevationFoldIn.ExistingCell]] = [:]
            for k in keys { grouped[k] = [] }
            for r in rows {
                grouped[r.hole_key, default: []].append(
                    ElevationFoldIn.ExistingCell(
                        cell_lat: r.cell_lat,
                        cell_lon: r.cell_lon,
                        mean_alt_m: r.mean_alt_m,
                        n_samples: r.n_samples
                    )
                )
            }
            cellsByHoleKey = grouped

            ClientEventLogger.log("elevation.cache.loaded", detail: [
                "courseId": .string(courseId.uuidString),
                "holeCount": .integer(holeNumbers.count),
                "cellCount": .integer(rows.count)
            ])
        } catch {
            ClientEventLogger.log("elevation.cache.load.failed", detail: [
                "courseId": .string(courseId.uuidString),
                "holeCount": .integer(holeNumbers.count),
                "error": .string(String(describing: error).prefix(200).description)
            ])
        }
    }

    /// Cells for one hole. Empty array = loaded but none exist yet.
    /// Nil = not loaded for this course (caller should treat as empty
    /// and the readout will show `—`).
    func cells(forKey key: String) -> [ElevationFoldIn.ExistingCell]? {
        cellsByHoleKey[key]
    }

    /// Wipe the cache. Called when a round ends so a fresh round at a
    /// different course doesn't see stale entries.
    func clear() {
        cellsByHoleKey.removeAll()
    }
}
