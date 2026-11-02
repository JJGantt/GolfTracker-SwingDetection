import Foundation
import CoreLocation
import Supabase

/// Client-side per-round fold-in into the shared `hole_height_cells` table.
/// Runs once at round end, for the whole course at once.
///
/// Steps:
/// 1. Pull existing cells for the course.
/// 2. Find spatial crossings (this round's PathSamples whose quantized
///    cell already exists in the table).
/// 3. Solve a 1-variable weighted offset for the round (cells fixed,
///    only the round's altimeter offset is unknown).
/// 4. Apply offset to all of this round's samples.
/// 5. Bucket corrected readings into 3 m cells, compute per-cell
///    weighted-mean altitude + total sample_count.
/// 6. RPC `upsert_course_height_cells` to atomically merge with whatever
///    other clients may have folded in concurrently.
///
/// First round at a course has no existing cells → no crossings →
/// offset = 0 → readings inserted directly as fresh cells. The round
/// becomes the reference frame for everyone after.
///
/// NOT PER HOLE (changed in migration 00045). The map is addressed by
/// position alone. A reading's `hole_number` is whatever hole the app was
/// counting at capture time, set by AutoAdvanceMonitor, whose triggers B and
/// C fire on proximity to the next hole with no putt gate. When it advances
/// early the readings still land on the right ground and used to be filed at
/// the wrong address — at Hyde Park every reading on hole 15's green carries
/// the label 16. Folding per hole also discarded every crossing between two
/// rounds on different holes (adjacent green and tee, a shared cart path),
/// which is a quarter of the available constraints.
enum ElevationFoldIn {

    /// Quantization step in degrees. ~3.3 m latitude everywhere; ~2.4-2.9 m
    /// longitude at typical golf latitudes (25-45°N). Both client and
    /// server-side aggregation MUST use this value or cells won't align
    /// across rounds.
    static let cellStepDeg: Double = 3e-5

    /// Rows per page for any read that can exceed PostgREST's default row cap.
    /// Matching that cap exactly means a full page is the signal to ask for
    /// another one, and a short page is the signal to stop. Mirrors `READ_PAGE`
    /// in the edge functions.
    static let readPageSize = 1000

    /// Weight multiplier for a sample's GPS horizontal accuracy. With 3 m
    /// cells, only high-fidelity fixes place a sample in the RIGHT cell —
    /// full weight at ≤5 m, linear taper to zero at 10 m, excluded beyond.
    /// nil (legacy rows captured before h_acc existed, or invalid fixes)
    /// gets a middling 0.5 so the pre-existing map keeps working.
    static func accuracyFactor(_ hAccMeters: Double?) -> Double {
        guard let a = hAccMeters else { return 0.5 }
        if a <= 5 { return 1.0 }
        if a >= 10 { return 0.0 }
        return (10 - a) / 5
    }

    /// A sample's effective count after accuracy weighting — used in place
    /// of raw `sample_count` for crossings, bucket means, and cell
    /// confidence. 0 means "exclude this sample".
    static func effectiveCount(sampleCount: Int, hAccMeters: Double?) -> Int {
        Int((Double(sampleCount) * accuracyFactor(hAccMeters)).rounded())
    }

    /// Integer cell index for a coordinate. Use this (not the quantized
    /// Double) as a dictionary key: neighbor cells computed via
    /// `center + di * step` float arithmetic differ from `quantize()`
    /// output in the last ULP ~34% of the time, silently missing the
    /// lookup. Integer indices make neighbor math exact.
    /// Sustained ground speed (m/s) above which the device is taken to be in a
    /// vehicle. Mirrors `VEHICLE_SPEED_MPS` in the edge function's solver.ts;
    /// both paths must agree or the client seeds cells the re-solve then throws
    /// away. Measured: play tops out at 9.09 m/s over a 15 s window, the drive
    /// home runs a median of 13.0.
    static let vehicleSpeedMps: Double = 9.0

    /// Window over which speed is averaged. Long enough that one bad fix can't
    /// trip the latch.
    static let vehicleWindowSeconds: TimeInterval = 15

    /// Drops the tail of a round from the moment it first moves at sustained
    /// vehicle speed.
    ///
    /// A phone in a car reads cabin pressure, not altitude — HVAC, windows and
    /// vehicle speed all move it. On the reference set, four rounds drove the
    /// same 2.5 km home and their altitude traces disagreed by 3-5 m along
    /// identical pavement, against a drift budget of 0.25 m. Because every
    /// round drives the SAME road, those readings generate plentiful crossings
    /// that look mutually consistent while encoding the wrong quantity.
    ///
    /// A latch rather than a per-sample filter: a car at a stop sign reads like
    /// a cart, but nobody parks and resumes golfing, so the first sustained
    /// crossing ends the round.
    ///
    /// Samples without `recorded_at` (legacy rows) are returned untouched.
    static func dropVehicleTail(_ samples: [SampleInput]) -> [SampleInput] {
        let timed = samples.compactMap { s -> (SampleInput, Date)? in
            guard let t = s.recorded_at else { return nil }
            return (s, t)
        }
        guard timed.count == samples.count, timed.count > 1 else { return samples }

        let rows = timed.sorted { $0.1 < $1.1 }
        var j = 0
        for i in 0..<rows.count {
            if j < i { j = i }
            while j + 1 < rows.count,
                  rows[j].1.timeIntervalSince(rows[i].1) < vehicleWindowSeconds {
                j += 1
            }
            let dt = rows[j].1.timeIntervalSince(rows[i].1)
            // Too short a span to judge: end of the round, or a sampling gap.
            guard dt >= vehicleWindowSeconds / 3 else { continue }
            let mLon = 111_320.0 * cos(rows[i].0.lat * .pi / 180)
            let dx = (rows[j].0.lon - rows[i].0.lon) * mLon
            let dy = (rows[j].0.lat - rows[i].0.lat) * 111_320.0
            if (dx * dx + dy * dy).squareRoot() / dt >= vehicleSpeedMps {
                return rows[0..<i].map(\.0)
            }
        }
        return samples
    }

    static func cellIndex(_ value: Double) -> Int {
        Int((value / cellStepDeg).rounded())
    }

    /// One row from `hole_height_cells`.
    struct ExistingCell: Decodable {
        let cell_lat: Double
        let cell_lon: Double
        let mean_alt_m: Double
        let n_samples: Int
    }

    /// One sample input. Mirrors a `round_altitude_readings` row but
    /// decoupled — only the fields the fold-in math uses.
    struct SampleInput: Decodable {
        let hole_number: Int
        let lat: Double
        let lon: Double
        let rel_alt_meters: Double
        let sample_count: Int
        /// GPS horizontal accuracy (m) at capture. Nil on legacy rows.
        let h_acc: Double?
        /// Capture time. Only the vehicle guard uses it. Nil on legacy rows,
        /// which simply skip the guard.
        let recorded_at: Date?
    }

    /// Per-cell delta payload for the upsert RPC.
    private struct CellDelta: Encodable {
        let lat: Double
        let lon: Double
        let mean_alt_m: Double
        let n_samples: Int
    }

    private struct UpsertParams: Encodable {
        let p_course_id: UUID
        let p_deltas: [CellDelta]
    }

    // MARK: - Durable entry point

    /// Persisted record of a fold-in that hasn't fully completed.
    /// The marker is written before any network work and cleared on success, so a
    /// retry never double-merges a hole that already landed.
    struct PendingFoldIn: Codable {
        let courseId: UUID
        let roundId: UUID
    }

    private static let pendingKey = "pendingElevationFoldIns"

    private static func loadPending() -> [PendingFoldIn] {
        guard let data = UserDefaults.standard.data(forKey: pendingKey),
              let list = try? JSONDecoder().decode([PendingFoldIn].self, from: data) else { return [] }
        return list
    }

    private static func savePending(_ list: [PendingFoldIn]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: pendingKey)
    }

    private static func upsertPending(_ marker: PendingFoldIn) {
        var list = loadPending()
        if let i = list.firstIndex(where: { $0.roundId == marker.roundId }) {
            list[i] = marker
        } else {
            list.append(marker)
        }
        savePending(list)
    }

    private static func clearPending(roundId: UUID) {
        savePending(loadPending().filter { $0.roundId != roundId })
    }

    /// Durable top-level entry — call this from `endRound`. Persists a
    /// pending marker before doing any network work, so an app
    /// suspension mid-fold (the round often ends right as the user
    /// pockets the device) just defers the work to `retryPending()`
    /// instead of silently dropping it forever.
    static func run(courseId: UUID, roundId: UUID) async {
        let marker = loadPending().first(where: { $0.roundId == roundId })
            ?? PendingFoldIn(courseId: courseId, roundId: roundId)
        upsertPending(marker)
        await attempt(marker)
    }

    /// Re-attempt every fold-in that never completed. Call on app
    /// foreground / app start. No-op when nothing is pending.
    static func retryPending() async {
        for marker in loadPending() {
            await attempt(marker)
        }
    }

    /// One fold-in attempt. Pulls this round's rows from
    /// `round_altitude_readings`, splits by hole, processes each hole not
    /// already folded by a prior attempt. Per-hole successes persist to
    /// the marker immediately; the marker clears only when every hole
    /// has landed. Pulling from the DB (not from
    /// LocationManager.pathSamples) means crash-recovered rows uploaded
    /// late this session also fold in — single source of truth is the
    /// table, not in-memory state.
    private static func attempt(_ marker: PendingFoldIn) async {
        let supabase = SupabaseManager.shared.client
        let roundId = marker.roundId

        // Paged. A 9-hole round is ~1400 readings and 18 holes ~2400, both past
        // PostgREST's 1000-row cap on an unbounded select — which this used to
        // be, so every fold-in was solving its offset from the first third of
        // the round and dropping the rest without saying so.
        var fetched: [SampleInput] = []
        do {
            var from = 0
            while true {
                let page: [SampleInput] = try await supabase
                    .from("round_altitude_readings")
                    .select("hole_number,lat,lon,rel_alt_meters,sample_count,h_acc,recorded_at")
                    .eq("round_id", value: roundId.uuidString)
                    .order("id", ascending: true)
                    .range(from: from, to: from + Self.readPageSize - 1)
                    .execute()
                    .value
                fetched.append(contentsOf: page)
                if page.count < Self.readPageSize { break }
                from += Self.readPageSize
            }
        } catch {
            ClientEventLogger.log("elevation.foldin.fetch.failed", detail: [
                "roundId": .string(roundId.uuidString),
                "error": .string(String(describing: error).prefix(200).description)
            ])
            return  // marker stays; retryPending will re-attempt
        }

        guard !fetched.isEmpty else {
            ClientEventLogger.log("elevation.foldin.skipped", detail: [
                "reason": .string("no_samples"),
                "roundId": .string(roundId.uuidString)
            ])
            clearPending(roundId: roundId)
            return
        }

        // Cut the drive home before anything is folded in. See dropVehicleTail.
        let onCourse = dropVehicleTail(fetched)
        if onCourse.count < fetched.count {
            ClientEventLogger.log("elevation.foldin.vehicle_tail_dropped", detail: [
                "roundId": .string(roundId.uuidString),
                "dropped": .integer(fetched.count - onCourse.count),
                "kept": .integer(onCourse.count)
            ])
        }
        guard !onCourse.isEmpty else {
            ClientEventLogger.log("elevation.foldin.skipped", detail: [
                "reason": .string("all_samples_at_vehicle_speed"),
                "roundId": .string(roundId.uuidString)
            ])
            clearPending(roundId: roundId)
            return
        }
        let samples = onCourse

        // Green centroids for this course, used to gate seeding. Pulled from
        // the shared `holes` table rather than the round, so it works on the
        // retry path where the round may no longer be loaded locally.
        // A number can have a shared row and the user's own; theirs wins.
        struct GreenRow: Decodable { let number: Int; let latitude: Double?; let longitude: Double?; let owner_id: UUID? }
        var greensByHole: [Int: CLLocationCoordinate2D] = [:]
        if let rows: [GreenRow] = try? await supabase
            .from("holes")
            .select("number,latitude,longitude,owner_id")
            .eq("course_id", value: marker.courseId.uuidString)
            .execute()
            .value {
            for r in rows.sorted(by: { ($0.owner_id == nil ? 0 : 1) < ($1.owner_id == nil ? 0 : 1) }) {
                guard let la = r.latitude, let lo = r.longitude else { continue }
                greensByHole[r.number] = CLLocationCoordinate2D(latitude: la, longitude: lo)
            }
        }

        let greens = Array(greensByHole.values)
        do {
            try await foldInCourse(courseId: marker.courseId, samples: samples, greens: greens)
            clearPending(roundId: roundId)
            ClientEventLogger.log("elevation.foldin.done", detail: [
                "roundId": .string(roundId.uuidString),
                "courseId": .string(marker.courseId.uuidString),
                "totalSamples": .integer(samples.count)
            ])
        } catch {
            // Marker stays; retryPending re-attempts. The fold is one atomic
            // RPC, so a failure leaves nothing half-written and a retry is
            // safe — unlike the old per-hole loop, which could get partway
            // through a round and need per-hole progress tracked to avoid
            // double-merging.
            ClientEventLogger.log("elevation.foldin.failed", detail: [
                "roundId": .string(roundId.uuidString),
                "sampleCount": .integer(samples.count),
                "error": .string(String(describing: error).prefix(200).description)
            ])
        }

        // Re-solve REGARDLESS of whether the fold-in succeeded.
        //
        // The fold-in is the fast path: one constant offset for the round,
        // enough to refresh the map at round end. The re-solve is the correct
        // one: it rebuilds the whole course from every round's raw readings.
        //
        // Deliberately outside the catch. The rounds that fail to fold in are
        // exactly the ones that could not solve an offset against the existing
        // map, and those are precisely the rounds a global re-solve rescues —
        // it has every round's readings to work with rather than one round and
        // a fixed map. Gating the re-solve on the fold-in succeeding would
        // withhold it from the case that needs it most. The raw readings are
        // already uploaded either way, so there is always something to solve.
        await requestGlobalResolve(courseId: marker.courseId)
    }

    /// How close a sample must come to the green for the round to count as
    /// having actually played the hole. A green is 20-30 m across, so 30 m
    /// means "on or beside the putting surface" without demanding the player
    /// walked over the centroid.
    static let reachedGreenMeters: Double = 30

    /// Did this round reach any green?
    ///
    /// Gates the FIRST data ever seeded for a course. Path recording runs
    /// whenever a round is live, including the walk in from the car and the
    /// walk back to the clubhouse, and those samples carry whatever hole
    /// number the round happened to be sitting on. Seeded unchecked, they
    /// create a hole's entire cell map hundreds of metres from the actual
    /// green — and because a later, correct round then finds zero crossings
    /// with them, it's discarded as uncalibrated and the bad map is locked in
    /// permanently. Requiring the green means the seed can only come from a
    /// round we know actually played.
    static func reachedGreen(samples: [SampleInput], green: CLLocationCoordinate2D) -> Bool {
        let g = CLLocation(latitude: green.latitude, longitude: green.longitude)
        return samples.contains {
            CLLocation(latitude: $0.lat, longitude: $0.lon).distance(from: g) <= reachedGreenMeters
        }
    }

    /// - Parameter greens: every green centroid on the course, used to gate
    ///   seeding. Empty means we can't check, so seeding is allowed (a manual
    ///   round whose pins aren't placed yet shouldn't lose its elevation data).
    private static func foldInCourse(courseId: UUID,
                                     samples: [SampleInput],
                                     greens: [CLLocationCoordinate2D]) async throws {
        let supabase = SupabaseManager.shared.client

        // Via the field endpoint, which pages server-side. Reading the table
        // here directly capped this at PostgREST's first 1000 rows, so the
        // offset was solved against a fraction of the map and every crossing
        // outside that slice was thrown away — silently, because a short read
        // looks exactly like a course nobody has walked.
        //
        // Deliberately not `HoleHeightCellCache.shared`: that snapshot is
        // whatever loaded at round start, and this runs at round end against
        // a map other rounds may have moved underneath it.
        let existingByCell: [CellKey: ExistingCell]
        switch try await HoleHeightCellCache.fetchField(courseId: courseId) {
        case let .fresh(field, _, _):
            existingByCell = field
        case .unchanged:
            // Unreachable: `unchanged` is only returned when a solve stamp was
            // supplied, and this call sends none.
            existingByCell = [:]
        }

        // -- Step 1: find crossings, solve weighted offset -------------------
        // For each sample, compute its cell. If that cell exists in the
        // historical map, it's a crossing. The implied offset for this
        // round is `cell.mean_alt_m - sample.relAlt`. Weighted mean of
        // implied offsets across all crossings = the round's offset.
        var weightedOffsetNumerator: Double = 0
        var weightSum: Double = 0
        var crossingCount = 0
        for s in samples {
            guard let cell = existingByCell[CellKey(i: cellIndex(s.lat), j: cellIndex(s.lon))] else {
                continue
            }
            let effCount = effectiveCount(sampleCount: s.sample_count, hAccMeters: s.h_acc)
            let weight = Double(min(effCount, cell.n_samples))
            guard weight > 0 else { continue }
            let implied = cell.mean_alt_m - s.rel_alt_meters
            weightedOffsetNumerator += weight * implied
            weightSum += weight
            crossingCount += 1
        }
        let offset: Double = weightSum > 0 ? (weightedOffsetNumerator / weightSum) : 0

        let isFirstRoundOnCourse = existingByCell.isEmpty
        // Seeding a course is a one-way decision: whatever lands first defines
        // the frame every later round is calibrated against, and a wrong seed
        // can't be displaced because later rounds won't cross it. So the seed
        // has to come from a round that demonstrably played golf here.
        if isFirstRoundOnCourse, !greens.isEmpty,
           !greens.contains(where: { reachedGreen(samples: samples, green: $0) }) {
            ClientEventLogger.log("elevation.foldin.seedRejected", detail: [
                "courseId": .string(courseId.uuidString),
                "sampleCount": .integer(samples.count),
                "reason": .string("never_reached_a_green")
            ])
            return
        }
        // Uncalibrated: cells exist but this round crossed none of them, so no
        // offset can be solved honestly. Now a course-wide test rather than a
        // per-hole one, which is the point — a round that crossed nothing on
        // hole 7 but plenty on holes 1-6 used to have its hole 7 data thrown
        // away despite its frame being fully determined. The raw readings
        // survive either way and a re-solve can pick them up.
        let isUncalibrated = !existingByCell.isEmpty && crossingCount == 0
        if isUncalibrated {
            ClientEventLogger.log("elevation.foldin.uncalibrated", detail: [
                "courseId": .string(courseId.uuidString),
                "existingCells": .integer(existingByCell.count),
                "sampleCount": .integer(samples.count)
            ])
            return
        }

        // -- Step 2: bucket corrected readings into per-cell deltas ----------
        // Per cell: weighted-mean of (sample.relAlt + offset), weight =
        // sample.sampleCount; total n_samples = sum of sample.sampleCount.
        struct Bucket {
            var weightedAltSum: Double = 0
            var weightSum: Double = 0  // weight in the mean (= sampleCount)
            var nSum: Int = 0          // total sample_count contributed
        }
        var buckets: [CellKey: Bucket] = [:]
        for s in samples {
            // Low-fidelity fixes can't be trusted to land in the right
            // 3 m cell — they're down-weighted or excluded entirely.
            let effCount = effectiveCount(sampleCount: s.sample_count, hAccMeters: s.h_acc)
            guard effCount > 0 else { continue }
            let key = CellKey(i: cellIndex(s.lat), j: cellIndex(s.lon))
            let corrected = s.rel_alt_meters + offset
            let w = Double(effCount)
            var b = buckets[key] ?? Bucket()
            b.weightedAltSum += w * corrected
            b.weightSum += w
            b.nSum += effCount
            buckets[key] = b
        }

        let deltas: [CellDelta] = buckets.compactMap { (key, b) in
            guard b.weightSum > 0, b.nSum > 0 else { return nil }
            return CellDelta(
                lat: Double(key.i) * cellStepDeg,
                lon: Double(key.j) * cellStepDeg,
                mean_alt_m: b.weightedAltSum / b.weightSum,
                n_samples: b.nSum
            )
        }

        guard !deltas.isEmpty else { return }

        // -- Step 3: atomic merge via RPC ------------------------------------
        try await supabase
            .rpc("upsert_course_height_cells",
                 params: UpsertParams(p_course_id: courseId, p_deltas: deltas))
            .execute()

        ClientEventLogger.log("elevation.foldin.ok", detail: [
            "courseId": .string(courseId.uuidString),
            "existingCells": .integer(existingByCell.count),
            "crossings": .integer(crossingCount),
            "offsetMeters": .double(offset),
            "deltaCells": .integer(deltas.count),
            "seed": .bool(isFirstRoundOnCourse)
        ])
    }

    /// Ask the `resolve-hole-heights` edge function to rebuild this course's
    /// map from raw readings.
    ///
    /// The fold-in above is the fast path: one constant offset for the whole
    /// round, which updates the map immediately at round end. The re-solve is
    /// the good one: it rebuilds the whole course from every round's raw
    /// readings.
    ///
    /// Best-effort and deliberately non-fatal: the fold-in has already updated
    /// the map, so failing here costs freshness, not data. The function is
    /// idempotent — it replaces the course's cells wholesale from
    /// `round_altitude_readings`, which is retained in full — so repeated or
    /// concurrent calls converge on the same answer.
    static func requestGlobalResolve(courseId: UUID) async {
        struct Body: Encodable { let courseId: String }
        do {
            let url = SupabaseManager.shared.projectURL
                .appendingPathComponent("functions/v1/resolve-hole-heights")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let session = try await SupabaseManager.shared.client.auth.session
            req.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONEncoder().encode(Body(courseId: courseId.uuidString))
            req.timeoutInterval = 180
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            ClientEventLogger.log("elevation.resolve.requested", detail: [
                "courseId": .string(courseId.uuidString),
                "status": .integer(code),
                "detail": .string(String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
            ])
        } catch {
            ClientEventLogger.log("elevation.resolve.failed", detail: [
                "courseId": .string(courseId.uuidString),
                "error": .string(String(describing: error).prefix(200).description)
            ])
        }
    }

    /// Hashable key for `[CellKey: T]` lookups — integer cell indices,
    /// exact under neighbor arithmetic (raw-Double keys missed ~34% of
    /// ring lookups from last-ULP float differences).
    struct CellKey: Hashable {
        let i: Int
        let j: Int
    }
}
