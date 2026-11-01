import Foundation
import StrokeSaverAlgorithms

/// Detector thresholds, sourced from the `detector_config` table.
///
/// Tuning used to require editing constants, building, uploading, and waiting
/// for the watch app to sync — minutes per experiment, for experiments that
/// take seconds to judge. Worse, it raced the analysis: what a stroke was
/// measured against was whatever happened to be compiled into the build on the
/// wrist that day, and nothing recorded which.
///
/// The table is the ONLY source of truth. The resolved set is handed to the
/// detector package through `DetectorParameters.install`, which every gate and
/// detector threshold reads; there is no threshold literal in the binary.
/// `isLoaded` gates detection, so a device that has never
/// resolved a config does not detect at all rather than detecting against
/// values nobody chose. The app needs the network regardless, and a disk cache
/// covers a later launch offline, so refusing is honest rather than fragile —
/// and far better than silently gating strokes with stale numbers.
///
/// Precedence on read: a row for this user overrides the shared default
/// (`user_id IS NULL`), so a personal override never requires touching the
/// baseline everyone else reads.
@MainActor
final class DetectorConfig: ObservableObject {
    static let shared = DetectorConfig()

    /// Values as last resolved. Empty until the first successful load, at which
    /// point the compiled defaults are what is actually in force.
    @Published private(set) var values: [String: Double] = [:]

    /// Whether real thresholds are in force. Detection is gated on this: the
    /// compiled literals exist only because Swift requires stored properties to
    /// be initialised, and must never be what a stroke is judged against.
    var isLoaded: Bool { !values.isEmpty }

    @Published private(set) var loadedAt: Date?
    /// Where the live values came from, for the record on every uploaded row.
    @Published private(set) var source: String = "compiled"

    private let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("detector_config.json")
    }()

    private init() { adoptCachedIfAvailable() }

    // MARK: - Loading

    /// Adopt the last good config off disk. Called at init so a launch with no
    /// network still runs the most recent tuning rather than silently reverting
    /// to whatever shipped in the binary.
    private func adoptCachedIfAvailable() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode([String: Double].self, from: data),
              !cached.isEmpty else { return }
        values = cached
        DetectorParameters.install(cached)
        source = "cache"
    }

    private struct Row: Decodable {
        let user_id: String?
        let key: String
        let value: Double
    }

    /// Fetch and apply. Safe to call often — a failure leaves whatever is
    /// already in force untouched, so a dropped connection mid-round never
    /// changes the detector's behaviour partway through.
    func refresh() async {
        do {
            let rows: [Row] = try await SupabaseManager.shared
                .from("detector_config").select().execute().value
            guard !rows.isEmpty else { return }
            let uid = WatchAuthSession.shared.currentUserId?.lowercased()
            var resolved: [String: Double] = [:]
            for r in rows where r.user_id == nil { resolved[r.key] = r.value }
            // User rows land second so they win.
            for r in rows where r.user_id?.lowercased() == uid && uid != nil {
                resolved[r.key] = r.value
            }
            values = resolved
            DetectorParameters.install(resolved)
            loadedAt = Date()
            source = "remote"
            try? JSONEncoder().encode(resolved).write(to: cacheURL, options: .atomic)
            ClientEventLogger.log("detectorConfig.loaded", detail: [
                "count": .integer(resolved.count),
                "source": .string("remote")
            ])
        } catch {
            ClientEventLogger.log("detectorConfig.loadFailed", detail: [
                "error": .string("\(error)"),
                "inForce": .string(source)
            ])
        }
    }

    // MARK: - Applying

    /// Thresholds are read through `DetectorParameters.d(_:)` / `i(_:)` at the
    /// point of use, so there is nothing to copy into and no window where the
    /// detector and the table disagree.

    /// Snapshot stamped onto every uploaded detection and rejection, so a row
    /// stays interpretable after the thresholds move. Without it, rows from
    /// either side of a change get pooled and compared as if they meant the
    /// same thing.
    var snapshot: [String: Double] { values }
}
