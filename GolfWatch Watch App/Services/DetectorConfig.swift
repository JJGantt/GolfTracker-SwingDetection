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

    /// The set in force, as last installed. Empty until the first complete one.
    @Published private(set) var values: [String: Double] = [:]

    /// Whether a complete set of thresholds is in force. Detection is gated on
    /// this; there are no compiled thresholds to fall back on.
    var isLoaded: Bool { DetectorParameters.isLoaded }

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
              !cached.isEmpty,
              apply(cached, source: "cache") else { return }
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
            guard apply(resolved, source: "remote") else { return }
            loadedAt = Date()
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

    /// Installs a resolved set if it is complete. An incomplete one (the
    /// table lost a row the detector reads, or a value is not a number) is
    /// refused and reported, and the set already in force keeps judging
    /// strokes; it never reaches the cache.
    private func apply(_ resolved: [String: Double], source newSource: String) -> Bool {
        switch DetectorParameters.install(resolved) {
        case .installed:
            values = resolved
            source = newSource
            return true
        case let .rejected(missing, invalid):
            ClientEventLogger.log("detectorConfig.rejected", detail: [
                "source": .string(newSource),
                "missing": .string(missing.joined(separator: ",")),
                "invalid": .string(invalid.joined(separator: ",")),
                "inForce": .string(source)
            ])
            return false
        }
    }

    /// Thresholds are read through `DetectorParameters.d(_:)` / `i(_:)` at the
    /// point of use, so there is nothing to copy into and no window where the
    /// detector and the table disagree.

    /// Snapshot stamped onto every uploaded detection and rejection, so a row
    /// stays interpretable after the thresholds move. Without it, rows from
    /// either side of a change get pooled and compared as if they meant the
    /// same thing.
    var snapshot: [String: Double] { values }
}
