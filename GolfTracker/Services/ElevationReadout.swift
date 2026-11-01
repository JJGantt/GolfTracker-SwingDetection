import Foundation
import Combine
import CoreLocation

/// Live "elevation to green" readout for the active hole. Phase 1 of the
/// elevation design (the algorithms package repo's `docs/ELEVATION_TRACKING.md`). The displayed Δ is the
/// **calibrated altimeter signal only** — phase 2's GPS-fused estimate
/// is deferred.
///
/// Computation each tick (path sample append, hole change, configure):
/// 1. Solve a 1-variable weighted offset for the round (`cLive`) by
///    iterating this round's path samples and computing implied offsets
///    against the cached cell map at each sample's quantized cell.
///    Each crossing's weight decays as `exp(-(now - sample.timestamp) / τ)`
///    so older readings (and any drift they carry) fade out smoothly.
/// 2. Compute target elevation as a weighted neighborhood blend of the
///    cell map around the green centroid (5×5, ±2-cell radius), weighted
///    by `n_samples × proximity-to-center`. No display gate — every cell
///    contributes proportionally to its accumulated sample count.
/// 3. Compute user elevation as a tiered blend:
///    - Historical cell map at user's position (same neighborhood blend
///      as the target).
///    - The user's own current-round path samples bucketed into 3 m
///      cells, neighborhood-blended around the user's position. No
///      time-decay on this tier — same physical location implies the
///      sample was just taken (within minutes), so age doesn't matter.
///      User's path readings are in the user's frame; add `cLive` to
///      translate.
///    - Both tiers blend together when both have data, weighted by
///      their respective sample counts.
///    - Last-resort fallback: latest sample's `relAltMeters + cLive`.
/// 4. Δ = targetElev − userElev. Positive = green is above you.
///
/// Returns nil when:
/// - No active round configured.
/// - No cells loaded for this hole AND no current-round path samples.
/// - No crossings found yet (no historical anchor → can't translate the
///   user's frame into the shared frame).
/// - Test mode is on (real altimeter, fake GPS = misleading number).
@MainActor
final class ElevationReadout: ObservableObject {
    static let shared = ElevationReadout()

    /// Δ to green in meters. Positive = green higher than user.
    /// nil = not enough data to display, or readout is inactive.
    @Published private(set) var deltaToGreenMeters: Double?

    /// Time constant for exponential decay of calibration crossings, in
    /// minutes. Older path samples contribute less to the offset solve
    /// — this bounds the influence of drift over a multi-hour round
    /// without needing a hard per-hole reset (calibration carries
    /// smoothly across hole transitions). Tunable from the developer
    /// menu; UserDefaults key `elevationCalibTauMinutes`.
    static let decayTauKey = "elevationCalibTauMinutes"
    static let defaultDecayTauMinutes: Double = 25
    private var decayTauSeconds: TimeInterval {
        let v = UserDefaults.standard.double(forKey: Self.decayTauKey)
        return (v > 0 ? v : Self.defaultDecayTauMinutes) * 60
    }

    private var courseId: UUID?
    private var currentHoleNumber: Int?
    private var currentGreen: CLLocationCoordinate2D?
    private var samplesObserver: AnyCancellable?

    /// The hole the round's elevation tracking began on. Used to release
    /// the first-tee GPS sync hold once that hole is played through
    /// (`updateHole` to a different number). Nil until the first hole is
    /// seen for this round.
    private var syncHoldFirstHole: Int?

    /// Cached cell map for the current hole, keyed by quantized
    /// (cell_lat, cell_lon). Refreshed when `updateHole` switches holes.
    private var cellsByCoord: [ElevationFoldIn.CellKey: ElevationFoldIn.ExistingCell] = [:]

    /// Begin tracking. Call from `startRound` after `HoleHeightCellCache`
    /// has loaded the course's cells (so the first sample tick has data
    /// to look at). `roundId` is no longer needed here — the readout
    /// works off `pathSamples` + the current-hole cell map only.
    ///
    /// The play view's `.onAppear` usually pushes `updateHole` BEFORE this
    /// runs (start is gated on the async cell-cache fetch), so an
    /// already-pushed hole must survive — wiping it here left the readout
    /// dead on the round's first hole until the user changed holes.
    /// Stale state from a previous round can't leak in: `stop()` runs on
    /// every round end before the next round starts.
    func start(courseId: UUID) {
        self.courseId = courseId
        self.cellsByCoord = [:]
        // Reference hole for the sync-hold release (may already be set if
        // the play view pushed a hole before this async start ran).
        syncHoldFirstHole = currentHoleNumber
        if currentHoleNumber != nil {
            refreshCellCache()
        }
        recompute()

        samplesObserver = LocationManager.shared.$pathSamples
            .sink { [weak self] _ in
                Task { @MainActor in self?.recompute() }
            }
    }

    /// Update which hole we're on. Call from the play view whenever
    /// `Round.currentHoleNumber` changes (or initial appear). Pass the
    /// hole's green centroid — typically `Hole.coordinate` (which for
    /// OSM-resolved rounds is the green centroid, and for manual rounds
    /// is wherever the user dropped the marker).
    ///
    /// Note: `green` should be non-nil under normal play. If a manual
    /// round somehow reaches play with no marker placed (`Hole.coordinate`
    /// nil), the readout silently disappears — the play view should
    /// ensure the hole has a coordinate before this is called.
    func updateHole(number: Int, green: CLLocationCoordinate2D?) {
        if number != currentHoleNumber {
            currentHoleNumber = number
            refreshCellCache()
        }
        // First-tee sync hold: release once the round's first hole is
        // played through (advanced to a different hole). The other release
        // paths (offset solved / no history on the hole) live in
        // currentSharedFrame().
        if let first = syncHoldFirstHole {
            if number != first {
                LocationManager.shared.releaseElevationSyncHold()
            }
        } else {
            syncHoldFirstHole = number
        }
        currentGreen = green
        recompute()
    }

    /// Stop tracking. Call from `endRound`. Wipes the published value
    /// so any UI bound to `deltaToGreenMeters` clears immediately.
    func stop() {
        samplesObserver?.cancel()
        samplesObserver = nil
        courseId = nil
        currentHoleNumber = nil
        currentGreen = nil
        cellsByCoord = [:]
        syncHoldFirstHole = nil
        deltaToGreenMeters = nil
    }

    // MARK: - Compute

    /// Δ in meters from the user's current calibrated altitude to the
    /// elevation at any arbitrary point on the active hole. Same model
    /// as `deltaToGreenMeters` — solves the round's offset, looks up
    /// the target's elevation via the same neighborhood blend the green
    /// uses. Positive = target is above the user (uphill).
    func deltaMeters(to target: CLLocationCoordinate2D) -> Double? {
        guard let frame = currentSharedFrame() else { return nil }
        guard let targetAlt = elevationFromHistorical(near: target,
                                                     cellRadius: Self.targetCellRadius) else { return nil }
        return targetAlt - frame.userAltShared
    }

    /// Elevation change from `from` to `to` (positive = `to` is higher), both
    /// ends read from the historical cell map. A shot's rise or fall between
    /// where it was hit and where the next one was played — neither end is the
    /// user, so no live altitude or round calibration is involved.
    func deltaMeters(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double? {
        guard let fromAlt = elevationFromHistorical(near: from, cellRadius: Self.targetCellRadius),
              let toAlt = elevationFromHistorical(near: to, cellRadius: Self.targetCellRadius) else { return nil }
        return toAlt - fromAlt
    }

    private struct SharedFrame {
        let userAltShared: Double
        /// `cLive` is exposed so the user-side blend can translate
        /// user-path samples (which are in the user's frame) into the
        /// shared frame. Nil-safe path: if no `cLive` exists (no
        /// crossings yet), `userAltShared` is computed from the
        /// historical cell map alone — see `userElevationShared()`.
        let cLive: Double?
    }

    /// Solve the round's offset against the current hole's cell map and
    /// translate the user's current altitude into the shared frame.
    /// Combines historical-at-user-position and user-path-near-user
    /// when both are available; falls back to liveAlt + cLive if neither
    /// has data.
    private func currentSharedFrame() -> SharedFrame? {
        guard let _ = courseId, let _ = currentHoleNumber else { return nil }
        if LocationManager.shared.isTestModeEnabled { return nil }

        // (1) Calibration: solve cLive via time-decayed weighted average
        //     of crossings between this round's path samples and the
        //     cached cell map.
        let cLive = solveOffset()

        // First-tee fidelity hold: release once the round's offset has
        // solved (sync achieved), or when this hole has no historical
        // cells to sync against (holding full fidelity gains nothing).
        if cLive != nil || cellsByCoord.isEmpty {
            LocationManager.shared.releaseElevationSyncHold()
        }

        // (2) User elevation in the shared frame, blended across two
        //     sources: historical cell map at the user's position, and
        //     the user's own bucketed path samples around that position.
        guard let userAlt = userElevationShared(cLive: cLive) else { return nil }

        return SharedFrame(userAltShared: userAlt, cLive: cLive)
    }

    private func recompute() {
        guard let green = currentGreen else {
            deltaToGreenMeters = nil
            return
        }
        deltaToGreenMeters = deltaMeters(to: green)
    }

    // MARK: - Calibration (cLive)

    /// Time-decayed weighted average of implied per-crossing offsets.
    /// Each path sample contributes one observation per cached cell in
    /// its 5×5 neighborhood (±2 cells, ~6 m radius). The exact-cell
    /// match weighs heaviest; ring 1 half; ring 2 quarter. Each
    /// contribution: `min(s.sample_count, cell.n_samples) × proximity
    /// × exp(-age/τ)`.
    ///
    /// Neighborhood lookups (vs pure exact-cell) help two ways:
    /// - GPS noise (especially in `.moderate` mode) often puts a sample
    ///   in a cell adjacent to a populated one. Without neighborhood,
    ///   every such sample contributes nothing; with neighborhood, the
    ///   sample picks up a downweighted crossing.
    /// - Calibration converges faster on sparse-history holes — every
    ///   sample contributes up to 25 weighted observations rather than
    ///   0 or 1.
    /// Trade-off: a sample at quantized cell X compared against a
    /// cell at X+1 carries a small ground-truth-gradient bias (≈
    /// `cellSize × localSlope` ≈ 15 cm at typical course slopes).
    /// Across many crossings with mixed walking directions this
    /// averages down.
    /// Returns nil when no crossings exist in current data.
    private func solveOffset() -> Double? {
        guard !cellsByCoord.isEmpty else { return nil }
        let now = Date()
        let tau = decayTauSeconds
        var num = 0.0
        var den = 0.0
        for s in LocationManager.shared.pathSamples {
            guard let alt = s.relAltMeters else { continue }
            let age = now.timeIntervalSince(s.timestamp)
            let decay = exp(-age / tau)
            // Once decay drops below ~0.001, the contribution is
            // negligible (5+ time constants old). Skip to avoid noise
            // accumulation in the long tail.
            if decay < 0.001 { continue }
            // Low-fidelity fixes can't be trusted to land in the right
            // 3 m cell — down-weighted, excluded beyond 10 m accuracy.
            let effCount = ElevationFoldIn.effectiveCount(
                sampleCount: s.sampleCount, hAccMeters: s.horizontalAccuracyMeters)
            guard effCount > 0 else { continue }
            let centerI = ElevationFoldIn.cellIndex(s.coordinate.latitude)
            let centerJ = ElevationFoldIn.cellIndex(s.coordinate.longitude)
            for di in -2...2 {
                for dj in -2...2 {
                    guard let cell = cellsByCoord[ElevationFoldIn.CellKey(i: centerI + di, j: centerJ + dj)] else { continue }
                    // Barely-observed ground is not a calibration reference.
                    guard cell.n_samples >= Self.minCalibrationSupport else { continue }
                    let baseWeight = Double(min(effCount, cell.n_samples))
                    guard baseWeight > 0 else { continue }
                    let prox = proximityWeight(di: di, dj: dj)
                    let weight = baseWeight * prox * decay
                    num += weight * (cell.mean_alt_m - alt)
                    den += weight
                }
            }
        }
        guard den > 0 else { return nil }
        return num / den
    }

    // MARK: - User elevation (tiered)

    /// User's elevation in the shared frame, blended across the two
    /// available data sources. Returns nil only when neither tier has
    /// any data and the live-fallback path also can't apply (no
    /// `cLive`, no live reading).
    private func userElevationShared(cLive: Double?) -> Double? {
        let userCoord = LocationManager.shared.location?.coordinate
        guard let userCoord else {
            // No GPS fix — fall back to the latest sample's coord.
            return liveFallback(cLive: cLive)
        }

        // Tier 1: historical neighborhood blend at user's position.
        // Each cell contributes (mean_alt_m, weight = n_samples × proximity).
        let hist = elevationFromHistorical(near: userCoord)
        let histWeight = totalHistoricalWeight(near: userCoord)

        // Tier 2: user's own path samples bucketed and neighborhood-blended.
        // These are in the user's altimeter frame; need `cLive` to translate.
        let userPathRaw = elevationFromUserPath(near: userCoord)
        let userPathWeight = totalUserPathWeight(near: userCoord)

        // Combine. Historical weight dominates by accumulated n_samples
        // (typically 5-100+), user-path weight is per-round samples
        // (typically 1-30). Same units so we can blend directly.
        if let h = hist, let u = userPathRaw, let c = cLive,
           histWeight > 0, userPathWeight > 0 {
            let combined = (h * histWeight + (u + c) * userPathWeight)
                         / (histWeight + userPathWeight)
            return combined
        }
        if let h = hist {
            return h
        }
        if let u = userPathRaw, let c = cLive {
            return u + c
        }
        return liveFallback(cLive: cLive)
    }

    /// Last-resort path: take whichever path sample is most recent and
    /// add `cLive`. Only fires when neither historical cells nor
    /// bucketed user-path data are available near the user — typically
    /// a fresh round on a fresh course where the user has just stepped
    /// off the cart in untraversed terrain.
    private func liveFallback(cLive: Double?) -> Double? {
        guard let cLive else { return nil }
        guard let latest = LocationManager.shared.pathSamples.last(where: { $0.relAltMeters != nil }),
              let alt = latest.relAltMeters else { return nil }
        return alt + cLive
    }

    // MARK: - Neighborhood lookups

    /// How far to search around the USER's position: ±2 cells (~6 m). The
    /// user stands on a point, and tiers 2/3 cover them with their own live
    /// path samples, so this stays tight.
    private static let userCellRadius = 2
    /// How far to search around the GREEN: ±4 cells (~12 m).
    ///
    /// A green is 20-30 m across, so cells 12 m from the centroid are still
    /// on the putting surface — this samples the target, it doesn't smear
    /// into the surrounding terrain. The green centroid is also an OSM or
    /// hand-placed point rather than somewhere anyone necessarily walked, so
    /// a ±6 m window frequently found nothing and the readout silently
    /// vanished: measured against Hyde Park's map, 11 of 18 greens had no
    /// cells within 6 m but 8 holes clear 4 cells at 12 m.
    private static let targetCellRadius = 4

    /// A cell must carry at least this much accuracy-weighted support before it
    /// may CALIBRATE the live altimeter.
    ///
    /// Since the map became a solved field, every cell has a value, including
    /// ground that was barely walked. That is fine
    /// to display and unacceptable to take a reading from: calibration folds
    /// that value straight into `cLive`, and the error then rides every
    /// subsequent estimate until the next crossing. Averaging many crossings
    /// does not save you, because it removes the noise in the OFFSET, not the
    /// error in the cell you happen to be standing on.
    ///
    /// Mirrors the solver's own minimum node support. The target
    /// lookup deliberately does NOT gate: a green centroid is a fine place to
    /// interpolate a few metres, and refusing there would just blank the
    /// readout.
    static let minCalibrationSupport = 2

    /// Weighted neighborhood blend of historical cells around `coord`, over a
    /// `(2r+1)×(2r+1)` window. Each cell weighted by `n_samples × proximity`.
    /// No display gate. Returns nil if no cells exist in the window.
    private func elevationFromHistorical(near coord: CLLocationCoordinate2D,
                                         cellRadius: Int = ElevationReadout.userCellRadius) -> Double? {
        let centerI = ElevationFoldIn.cellIndex(coord.latitude)
        let centerJ = ElevationFoldIn.cellIndex(coord.longitude)
        var weighted: Double = 0
        var weightSum: Double = 0
        for di in -cellRadius...cellRadius {
            for dj in -cellRadius...cellRadius {
                guard let cell = cellsByCoord[ElevationFoldIn.CellKey(i: centerI + di, j: centerJ + dj)] else { continue }
                let prox = proximityWeight(di: di, dj: dj)
                let w = Double(cell.n_samples) * prox
                weighted += w * cell.mean_alt_m
                weightSum += w
            }
        }
        return weightSum > 0 ? (weighted / weightSum) : nil
    }

    private func totalHistoricalWeight(near coord: CLLocationCoordinate2D) -> Double {
        let centerI = ElevationFoldIn.cellIndex(coord.latitude)
        let centerJ = ElevationFoldIn.cellIndex(coord.longitude)
        var weightSum: Double = 0
        for di in -2...2 {
            for dj in -2...2 {
                guard let cell = cellsByCoord[ElevationFoldIn.CellKey(i: centerI + di, j: centerJ + dj)] else { continue }
                weightSum += Double(cell.n_samples) * proximityWeight(di: di, dj: dj)
            }
        }
        return weightSum
    }

    /// Bucket the round's path samples into 3 m cells (same quantization
    /// as the historical cell map), then neighborhood-blend around
    /// `coord`. Returns the raw user-frame elevation (caller adds
    /// `cLive` to translate to shared frame). No time-decay — same
    /// physical location implies the sample was recorded recently
    /// (within the duration of one shot), so age isn't a concern.
    private func elevationFromUserPath(near coord: CLLocationCoordinate2D) -> Double? {
        let buckets = bucketUserPathSamples()
        guard !buckets.isEmpty else { return nil }
        let centerI = ElevationFoldIn.cellIndex(coord.latitude)
        let centerJ = ElevationFoldIn.cellIndex(coord.longitude)
        var weighted: Double = 0
        var weightSum: Double = 0
        for di in -2...2 {
            for dj in -2...2 {
                guard let b = buckets[ElevationFoldIn.CellKey(i: centerI + di, j: centerJ + dj)] else { continue }
                let prox = proximityWeight(di: di, dj: dj)
                let w = Double(b.totalSampleCount) * prox
                weighted += w * b.meanAlt
                weightSum += w
            }
        }
        return weightSum > 0 ? (weighted / weightSum) : nil
    }

    private func totalUserPathWeight(near coord: CLLocationCoordinate2D) -> Double {
        let buckets = bucketUserPathSamples()
        guard !buckets.isEmpty else { return 0 }
        let centerI = ElevationFoldIn.cellIndex(coord.latitude)
        let centerJ = ElevationFoldIn.cellIndex(coord.longitude)
        var weightSum: Double = 0
        for di in -2...2 {
            for dj in -2...2 {
                guard let b = buckets[ElevationFoldIn.CellKey(i: centerI + di, j: centerJ + dj)] else { continue }
                weightSum += Double(b.totalSampleCount) * proximityWeight(di: di, dj: dj)
            }
        }
        return weightSum
    }

    /// 5×5 proximity weights. Center = 4, ring 1 = 2, ring 2 = 1. Lets
    /// the cell directly under the query point dominate when it has
    /// data, while still allowing surrounding cells to fill in
    /// gracefully when the center is missing or sparse.
    private func proximityWeight(di: Int, dj: Int) -> Double {
        let r = abs(di) + abs(dj)
        switch r {
        case 0: return 4.0
        case 1: return 2.0
        default: return 1.0
        }
    }

    /// One bucket per 3 m cell that the round's path samples land in.
    /// Aggregates `mean_alt_m` weighted by per-sample `sample_count`.
    /// Recomputed on each call (cheap — N is bounded by number of path
    /// samples in this round, typically a few thousand at end of round).
    private func bucketUserPathSamples() -> [ElevationFoldIn.CellKey: UserBucket] {
        var buckets: [ElevationFoldIn.CellKey: UserBucket] = [:]
        for s in LocationManager.shared.pathSamples {
            guard let alt = s.relAltMeters else { continue }
            let effCount = ElevationFoldIn.effectiveCount(
                sampleCount: s.sampleCount, hAccMeters: s.horizontalAccuracyMeters)
            guard effCount > 0 else { continue }
            let key = ElevationFoldIn.CellKey(i: ElevationFoldIn.cellIndex(s.coordinate.latitude),
                              j: ElevationFoldIn.cellIndex(s.coordinate.longitude))
            var b = buckets[key] ?? UserBucket()
            let w = Double(effCount)
            b.weightedAltSum += w * alt
            b.weightTotal += w
            b.totalSampleCount += effCount
            buckets[key] = b
        }
        return buckets
    }

    // MARK: - Cell cache helpers

    /// Take the course's whole map. Not per hole any more (migration 00045):
    /// cells are addressed by position, so a lookup near a green no longer
    /// misses ground that happens to sit under a neighbouring hole's key.
    private func refreshCellCache() {
        cellsByCoord = HoleHeightCellCache.shared.snapshot()
    }

    // MARK: - Types

    private struct UserBucket {
        var weightedAltSum: Double = 0
        var weightTotal: Double = 0
        var totalSampleCount: Int = 0
        var meanAlt: Double { weightTotal > 0 ? weightedAltSum / weightTotal : 0 }
    }
}
