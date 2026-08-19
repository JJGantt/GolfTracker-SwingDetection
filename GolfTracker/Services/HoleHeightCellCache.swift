import Foundation
import Supabase

/// In-memory cache of `hole_height_cells` rows for a round's course.
/// Loaded once at round start (one query for the whole course); read by
/// `ElevationReadout` on every path-sample tick.
///
/// Not refreshed mid-round. Other users' rounds folding in during our
/// round won't appear in our cache until our next round, which is the
/// acceptable freshness penalty for keeping the read path fast and
/// network-free during play.
///
/// The map is addressed by POSITION, not by hole (migration 00045), so this
/// holds one flat set of cells for the course. It used to group by hole_key,
/// which meant a lookup near a green could miss cells that were sitting a
/// metre away under a neighbouring hole's key.
///
/// `@MainActor` so all access is serialized through the main actor —
/// no need for an NSLock. The network fetch is `await`-ed off-actor;
/// only the dictionary mutation stays on-actor.
@MainActor
final class HoleHeightCellCache {
    static let shared = HoleHeightCellCache()

    /// Indexed by integer cell index, matching `ElevationFoldIn.cellIndex`.
    /// Nil (rather than empty) means "not loaded for a course yet", which the
    /// readout treats as no solution rather than as flat ground.
    private var cells: [ElevationFoldIn.CellKey: ElevationFoldIn.ExistingCell]?

    /// Load every cell for the course. Safe to call multiple times; replaces
    /// prior cache contents.
    func loadForCourse(courseId: UUID) async {
        let supabase = SupabaseManager.shared.client

        struct Row: Decodable {
            let cell_lat: Double
            let cell_lon: Double
            let mean_alt_m: Double
            let n_samples: Int
        }

        do {
            let rows: [Row] = try await supabase
                .from("hole_height_cells")
                .select("cell_lat,cell_lon,mean_alt_m,n_samples")
                .eq("course_id", value: courseId.uuidString)
                .execute()
                .value

            var loaded: [ElevationFoldIn.CellKey: ElevationFoldIn.ExistingCell] = [:]
            loaded.reserveCapacity(rows.count)
            for r in rows {
                let key = ElevationFoldIn.CellKey(i: ElevationFoldIn.cellIndex(r.cell_lat),
                                                 j: ElevationFoldIn.cellIndex(r.cell_lon))
                loaded[key] = ElevationFoldIn.ExistingCell(
                    cell_lat: r.cell_lat,
                    cell_lon: r.cell_lon,
                    mean_alt_m: r.mean_alt_m,
                    n_samples: r.n_samples
                )
            }
            cells = loaded

            ClientEventLogger.log("elevation.cache.loaded", detail: [
                "courseId": .string(courseId.uuidString),
                "cellCount": .integer(rows.count)
            ])
        } catch {
            ClientEventLogger.log("elevation.cache.load.failed", detail: [
                "courseId": .string(courseId.uuidString),
                "error": .string(String(describing: error).prefix(200).description)
            ])
        }
    }

    /// The cell covering a position, or nil if nothing has been recorded
    /// there. Nil is also returned before any course is loaded.
    func cell(at key: ElevationFoldIn.CellKey) -> ElevationFoldIn.ExistingCell? {
        cells?[key]
    }

    /// The whole map, for callers that want their own indexed copy.
    func snapshot() -> [ElevationFoldIn.CellKey: ElevationFoldIn.ExistingCell] {
        cells ?? [:]
    }

    /// Whether a course has been loaded at all. Distinguishes "no map yet"
    /// from "map exists but nothing near you".
    var isLoaded: Bool { cells != nil }

    /// How many cells the course has. Used for logging and for the
    /// first-tee fidelity hold's "is there anything to sync against" test.
    var count: Int { cells?.count ?? 0 }

    /// Wipe the cache. Called when a round ends so a fresh round at a
    /// different course doesn't see stale entries.
    func clear() {
        cells = nil
    }
}
