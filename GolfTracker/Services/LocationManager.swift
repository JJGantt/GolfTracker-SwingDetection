import Foundation
import CoreLocation
import CoreMotion
import Combine
import Supabase

/// LocationManager publishes via the classic `ObservableObject` /
/// `@Published` pattern. We previously tried the `@Observable` macro for
/// finer-grained per-property tracking, but that turned out to make
/// `ActiveRoundView` re-render more aggressively, not less, because the
/// view body reads many LocationManager properties (`location`, `heading`,
/// `gpsPowerMode`) and each became its own dependency edge. Coarse-grained
/// `objectWillChange` is, in practice, what works — SwiftUI batches
/// multiple @Published mutations into a single re-eval per runloop tick.
class LocationManager: NSObject, ObservableObject {
    static let shared = LocationManager()
    static let testCoordinate = CLLocationCoordinate2D(
        latitude: 30.285357365597697,
        longitude: -81.74623642434663
    )

    private let locationManager = CLLocationManager()
    private let altimeter = CMAltimeter()
    private var altimeterRunning = false
    /// Most recent altimeter reading, used by `currentRelativeAltitudeMeters`
    /// for one-shot consumers (e.g. capturing alt on a stroke). Updated on
    /// every CMAltimeter callback (~1 Hz).
    private var latestRelativeAltitudeMeters: Double?
    /// Altimeter readings (~1 Hz) collected since the last path sample
    /// was emitted. Each new path sample takes the MEDIAN of these and
    /// resets. Median, not mean: the wrist barometer reads wrist height,
    /// and bend-downs (teeing up, retrieving the ball — reads ~1 m low)
    /// and wrist-raises (reads high) are 2-3s transients that are a
    /// minority of the window's readings — the median never elects them,
    /// where the old mean let them bias every tee and cup cell in the
    /// height map. Standing-still rows accumulate many readings (cleaner
    /// signal); walking rows get 2-3. The modeling layer weights by
    /// count downstream. Capped so a long idle stretch can't grow it
    /// unbounded (stationary ⇒ true elevation constant, so a wide
    /// window stays valid).
    private var pathAltWindow: [Double] = []
    private let pathAltWindowCap = 600

    /// Read-only accessor for callers who want the most recent altimeter
    /// reading at a specific moment (stroke recording, etc.). Same anchor
    /// point as the path-sample data — values are comparable to each other
    /// within one round. Returns nil while GPS test mode is on so the
    /// real wrist-height reading isn't attached to a stroke at a fake
    /// location (poisons stroke-elevation analysis downstream).
    var currentRelativeAltitudeMeters: Double? {
        isTestModeEnabled ? nil : latestRelativeAltitudeMeters
    }

    @Published var location: CLLocation?
    @Published var heading: CLLocationDirection?

    /// Live compass heading, published on its own object rather than as a
    /// `@Published` here: every LocationManager publish re-evaluates the
    /// whole of `ActiveRoundView`, and a compass ticks far more often than
    /// GPS. Only the views that draw the heading observe this.
    final class Compass: ObservableObject {
        /// Degrees from true north (magnetic when true is unavailable);
        /// nil while no client is running it or the reading is invalid.
        @Published fileprivate(set) var degrees: CLLocationDirection?
    }
    let compass = Compass()
    /// Views currently showing the heading. The compass runs only while
    /// this is above zero, so its radio cost is confined to those screens.
    private var compassClients = 0

    /// One sample per ~3m of GPS movement during a round, paired with the
    /// latest barometric relative altitude. Replaces the old in-memory
    /// `Breadcrumb` rolling buffer — same data, no upper bound, plus
    /// elevation. Drives the watch's fading breadcrumb trail (UI takes
    /// `pathSamples.suffix(N)`) and feeds the upload queue for
    /// `round_altitude_readings`.
    struct PathSample: Identifiable {
        let id = UUID()
        let coordinate: CLLocationCoordinate2D
        let timestamp: Date
        let relAltMeters: Double?
        /// Number of altimeter readings averaged into `relAltMeters`. 1
        /// for walking-pace rows, many for stationary rows.
        let sampleCount: Int
        /// Hole the user was on when this sample was emitted. `nil` when no
        /// recording context is active (e.g. samples appended before
        /// `startPathRecording`, or after `stopPathRecording`).
        let holeNumber: Int?
        /// GPS horizontal accuracy (meters) of the fix this sample came
        /// from. Drives accuracy weighting in elevation calibration —
        /// full weight ≤5 m, taper to zero at 10 m. nil = invalid fix.
        let horizontalAccuracyMeters: Double?
    }
    @Published private(set) var pathSamples: [PathSample] = []
    private let pathSampleMinSpacingMeters: CLLocationDistance = 3

    /// Round-recording context. When non-nil, every new path sample is
    /// also queued for upload to `round_altitude_readings`. Cleared on
    /// `stopPathRecording`. The `holeNumberProvider` is read at sample
    /// time so each row carries the hole the user was on at capture
    /// (NOT at upload — by upload time the user may have advanced).
    private struct RecordingContext {
        let roundId: UUID
        let userId: String
        let holeNumberProvider: () -> Int
    }
    private var recordingContext: RecordingContext?
    /// In-memory queue of altitude rows pending upload to
    /// `round_altitude_readings`. Persisted to disk after every mutation
    /// (see `pathQueueURL`) so a force-quit, crash, app exit, or
    /// network outage doesn't drop captured samples. The on-disk JSON
    /// is the durable source of truth; `pendingUploadRows` is the live
    /// working copy. Loaded from disk on first round-start so any
    /// rows from a prior aborted session get drained.
    private var pendingUploadRows: [[String: Any]] = []
    private let pathQueueLock = NSLock()
    private lazy var pathQueueURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("path_upload_queue.json")
    }()
    /// Per-flush row cap. Keeps each PostgREST `insert` payload small so
    /// it has a better shot at completing over a flaky cell connection.
    /// On a successful flush we'll fire the next one immediately if
    /// there's still backlog instead of waiting for the next 30s tick.
    private let pathUploadChunkSize = 100
    /// Set during an in-flight flush so a 30s tick can't double-fire
    /// while we're still sending the previous batch.
    private var pathFlushInFlight: Bool = false
    /// When the in-flight flush began. A single hung request once held the
    /// flag for an entire round (2026-07-05: uploads stopped 13 min in and
    /// every later tick early-returned — holes 2-15 never flushed), so
    /// ticks reclaim the flag once it's been held past this deadline.
    private var pathFlushStartedAt: Date?
    private let pathFlushStaleSeconds: TimeInterval = 90
    private var uploadFlushTimer: Timer?

    private func appendPathSample(_ loc: CLLocation) {
        if let last = pathSamples.last {
            let prev = CLLocation(latitude: last.coordinate.latitude,
                                  longitude: last.coordinate.longitude)
            if loc.distance(from: prev) < pathSampleMinSpacingMeters { return }
        }
        // Take the MEDIAN of altimeter readings collected since the last
        // emit, then reset (see pathAltWindow for why median beats mean:
        // bend-down / wrist-raise transients). When stationary, this
        // captures the dozens of readings that would otherwise be
        // discarded between path samples — much cleaner signal at the
        // points where the user actually pauses (tees, greens). When
        // walking, this still works for the 2-3 readings collected
        // during the ~2s it takes to cover 3m.
        let windowAlt: Double? = {
            guard !pathAltWindow.isEmpty else { return latestRelativeAltitudeMeters }
            let sorted = pathAltWindow.sorted()
            let mid = sorted.count / 2
            return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
        }()
        let count = max(pathAltWindow.count, 1)
        pathAltWindow.removeAll(keepingCapacity: true)

        let holeNumberAtSample = recordingContext?.holeNumberProvider()
        let sample = PathSample(
            coordinate: loc.coordinate,
            timestamp: loc.timestamp,
            relAltMeters: windowAlt,
            sampleCount: count,
            holeNumber: holeNumberAtSample,
            horizontalAccuracyMeters: loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy : nil
        )
        pathSamples.append(sample)

        // GPS test mode: the barometer reading is real (the user's actual
        // wrist height), but the lat/lon is fake. Persisting the row would
        // attribute sensor data to a coordinate the user wasn't physically
        // at — exactly the data-integrity problem the test-mode flag was
        // added to avoid. So skip the upload entirely in test mode. The
        // in-memory pathSamples array still updates so the breadcrumb UI
        // works during testing.
        if let ctx = recordingContext, !isTestModeEnabled {
            let row: [String: Any] = [
                "id": UUID().uuidString,
                "round_id": ctx.roundId.uuidString,
                "user_id": ctx.userId,
                "hole_number": sample.holeNumber ?? ctx.holeNumberProvider(),
                "lat": sample.coordinate.latitude,
                "lon": sample.coordinate.longitude,
                "rel_alt_meters": sample.relAltMeters ?? 0,
                "sample_count": sample.sampleCount,
                "h_acc": sample.horizontalAccuracyMeters as Any? ?? NSNull(),
                "recorded_at": Self.iso(sample.timestamp)
            ]
            pathQueueLock.lock()
            pendingUploadRows.append(row)
            savePathQueueLocked()
            pathQueueLock.unlock()
        }
    }

    /// Write current `pendingUploadRows` to disk. Caller must hold
    /// `pathQueueLock`. Best-effort — a failed write doesn't surface
    /// errors; the next mutation overwrites it.
    private func savePathQueueLocked() {
        guard let data = try? JSONSerialization.data(withJSONObject: pendingUploadRows) else { return }
        try? data.write(to: pathQueueURL, options: .atomic)
    }

    /// Restore queued rows from disk (called once at first round-start).
    /// Lets a force-quit / crash / network outage during a prior round
    /// drain on the next round's flush cycle instead of being lost.
    private func loadPathQueueFromDisk() {
        pathQueueLock.lock()
        defer { pathQueueLock.unlock() }
        guard let data = try? Data(contentsOf: pathQueueURL),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return
        }
        // Prepend to anything already in memory — disk rows are older.
        pendingUploadRows = rows + pendingUploadRows
    }
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var errorMessage: String?
    @Published var isTestModeEnabled: Bool = false
    enum GPSPowerMode: String {
        case full       // kCLLocationAccuracyBest, 1m filter
        case moderate   // kCLLocationAccuracyNearestTenMeters, 10m filter
    }

    @Published var gpsPowerMode: GPSPowerMode = .full

    /// Combine publisher for non-view subscribers (background watchers like
    /// `AutoAdvanceMonitor` that use throttling/sinks). View code reads
    /// the `location` property directly via `@ObservedObject`/`@StateObject`
    /// and gets updates through the standard ObservableObject path.
    let locationPublisher = PassthroughSubject<CLLocation, Never>()

    /// User-controlled simulated location during test mode. When nil but
    /// test mode is on, falls back to the static testCoordinate so the
    /// app has *something* to use. Updated by `TestModeService` from
    /// Supabase Realtime when the iPhone Test Mode view writes a new pin.
    private var simulatedTestLocation: CLLocation?

    private var forcedTestLocation: CLLocation {
        simulatedTestLocation
            ?? CLLocation(latitude: Self.testCoordinate.latitude, longitude: Self.testCoordinate.longitude)
    }

    /// Push a new simulated location into the running app. Updates
    /// `location` and fires the `locationPublisher` so AutoAdvanceMonitor's
    /// throttled subscriber re-evaluates. Called from TestModeService when
    /// an inbound DB change lands. No-op when test mode isn't enabled —
    /// caller should flip test mode on first via `setTestModeEnabled(true)`.
    func applyTestLocation(_ coord: CLLocationCoordinate2D) {
        let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        simulatedTestLocation = loc
        guard isTestModeEnabled else { return }
        location = loc
        appendPathSample(loc)
        locationPublisher.send(loc)
        errorMessage = nil
    }

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 1 // Update every 1 meter
        // Heading runs only on demand — see `beginCompass()`. The round-play
        // map's user marker is a direction-less dot, so leaving the compass
        // on for the whole round would spend its radio cost on nothing.
        locationManager.headingFilter = 5

        // Enable background location updates (necessary for watchOS when screen is off)
        #if os(iOS) || os(watchOS)
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.activityType = .fitness // Golf is a fitness activity
        #endif

        #if os(iOS)
        locationManager.pausesLocationUpdatesAutomatically = false
        #endif

        #if targetEnvironment(simulator)
        // Set a default location for simulator testing
        location = CLLocation(latitude: 37.7749, longitude: -122.4194)
        #endif
    }

    func requestPermission() {
        // Don't bail on isTestModeEnabled here. Permission and live-GPS
        // tracking are separate — we can hold the OS-level permission
        // even while currently sourcing location from a test simulator,
        // and the user shouldn't be blocked from completing onboarding
        // just because test mode happens to be on.
        #if os(iOS) || os(watchOS)
        locationManager.requestWhenInUseAuthorization()
        #elseif os(macOS)
        // macOS doesn't require explicit permission request
        #endif
    }

    func setTestModeEnabled(_ enabled: Bool) {
        // Synchronous on whatever thread the caller is on. Used to dispatch
        // async to avoid SwiftUI "Publishing changes from within view
        // updates" warnings, but our actual call sites are background Tasks
        // (TestModeService.applyState / setTestModeEnabled toggle), not view
        // updates — and the async dispatch was creating a window where
        // isTestModeEnabled was still `false` when downstream code (like
        // ActiveRoundView.handleViewAppear → startTracking) ran, causing
        // real GPS to spin up and overwrite the simulated location.
        isTestModeEnabled = enabled
        if enabled {
            locationManager.stopUpdatingLocation()
            let forced = forcedTestLocation
            location = forced
            errorMessage = nil
            // Fire the Combine publisher so AutoAdvanceMonitor and any
            // other locationPublisher subscribers re-evaluate against the
            // simulated coord, same as a real GPS update.
            locationPublisher.send(forced)
            dprint("[LocationManager] Test mode ON: forcing location to \(forced.coordinate.latitude), \(forced.coordinate.longitude)")
        } else {
            simulatedTestLocation = nil
            dprint("[LocationManager] Test mode OFF: resuming live GPS")
            startTracking()
        }
    }

    func startTracking() {
        if isTestModeEnabled {
            location = forcedTestLocation
            heading = 0
            errorMessage = nil
            return
        }

        #if os(iOS) || os(watchOS)
        let isAuthorized = authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
        #elseif os(macOS)
        let isAuthorized = authorizationStatus == .authorizedAlways
        #endif

        dprint("[LocationManager] startTracking called - isAuthorized: \(isAuthorized), status: \(authorizationStatus.rawValue)")

        guard isAuthorized else {
            errorMessage = "Location permission not granted"
            dprint("[LocationManager] NOT authorized, skipping location updates")
            return
        }

        dprint("[LocationManager] Starting location updates")
        locationManager.startUpdatingLocation()
    }

    /// Start the compass for a view that draws the user's facing direction.
    /// Pair every call with `endCompass()`; the compass stops when the last
    /// client leaves.
    func beginCompass() {
        compassClients += 1
        guard compassClients == 1, CLLocationManager.headingAvailable() else { return }
        locationManager.startUpdatingHeading()
    }

    func endCompass() {
        guard compassClients > 0 else { return }
        compassClients -= 1
        guard compassClients == 0 else { return }
        locationManager.stopUpdatingHeading()
        compass.degrees = nil
    }

    func stopTracking() {
        locationManager.stopUpdatingLocation()
        gpsPowerMode = .full
    }

    /// Dev-menu UserDefaults key. When true, every `setGPSPowerMode`
    /// call is coerced to `.full` — bypassing the distance / putter
    /// heuristics that normally drop to `.moderate`. Useful for
    /// elevation calibration validation, where 10 m GPS noise can push
    /// samples into adjacent 3 m cells and miss historical crossings.
    /// Off by default; on respects power-management when toggled off.
    static let forceFullGPSKey = "elevationForceFullGPS"

    /// First-tee elevation sync hold. Set at round start; while active,
    /// every `setGPSPowerMode` call is coerced to `.full` so the round's
    /// first calibration crossings land at high fidelity (the first tee
    /// has no prior-green sync to lean on). Released by ElevationReadout
    /// once the offset solves, the hole has no history to sync against,
    /// or the round's first hole is played through. No time cap — a round
    /// can sit in a parking lot a while before reaching the first tee.
    private var elevationSyncHoldActive = false

    func releaseElevationSyncHold() {
        elevationSyncHoldActive = false
    }

    /// Tee hold. Active from arriving at a hole until that hole's first
    /// stroke is recorded; while active, `setGPSPowerMode` is coerced to
    /// `.full`.
    ///
    /// The distance heuristic alone leaves a hole in the height map. It runs
    /// `.full` inside `gpsModerateYards` (200 yd) of the pin, so the green and
    /// approach are well covered — but at the tee of a par 4 or 5 you're
    /// beyond that, so the walk from the previous green to this tee, and the
    /// tee shot itself, record at `.moderate`. `.moderate` requests 10 m
    /// accuracy, and `ElevationFoldIn.accuracyFactor` excludes anything at
    /// 10 m or worse outright — so that stretch burns GPS and then gets
    /// discarded. Measured across the existing readings: median accuracy
    /// 7.4 m, only 18% at the ≤5 m full-weight mark, 34% dropped entirely.
    ///
    /// The green and the tee are the two ends of the hole and both are
    /// elevation anchors; the middle of the fairway is the part that
    /// interpolates. So hold full fidelity across green → walk → next tee →
    /// first stroke, then let the distance heuristic take over until the
    /// approach brings it back inside 200 yd.
    private var teeHoldActive = false

    /// Call when the round moves to a new hole.
    func beginTeeHold() {
        teeHoldActive = true
        setGPSPowerMode(.full)
    }

    /// Call when a stroke is recorded — the tee shot is in the bag, so the
    /// distance heuristic can resume. No-op after the first stroke on a hole.
    func releaseTeeHoldIfNeeded() {
        guard teeHoldActive else { return }
        teeHoldActive = false
    }

    func setGPSPowerMode(_ mode: GPSPowerMode) {
        // Dev-menu force-full overrides the requested mode. Power-mgmt
        // callers stay unchanged — the override is applied here so any
        // downgrade attempt is silently coerced back to `.full`.
        var mode: GPSPowerMode = UserDefaults.standard.bool(forKey: Self.forceFullGPSKey) ? .full : mode
        if elevationSyncHoldActive || teeHoldActive { mode = .full }
        guard mode != gpsPowerMode, !isTestModeEnabled else { return }
        gpsPowerMode = mode

        switch mode {
        case .full:
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.distanceFilter = 1
            locationManager.startUpdatingLocation()
            dprint("[LocationManager] GPS: full (best accuracy, 1m filter)")

        case .moderate:
            locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            locationManager.distanceFilter = 10
            locationManager.startUpdatingLocation()
            dprint("[LocationManager] GPS: moderate (10m accuracy, 10m filter)")
        }
    }

    func distance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance? {
        guard let location = location else { return nil }
        let targetLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return location.distance(from: targetLocation)
    }

    func formattedDistance(to coordinate: CLLocationCoordinate2D?) -> String {
        guard let coordinate = coordinate else {
            return "No flag placed"
        }
        guard let distance = distance(to: coordinate) else {
            return "Searching for GPS..."
        }

        // Convert meters to yards
        let yards = distance * 1.09361

        if yards < 1000 {
            return String(format: "%.0f yards", yards)
        } else {
            let miles = yards / 1760
            return String(format: "%.2f miles", miles)
        }
    }

    /// Get current location synchronously (uses last known location if available)
    func getCurrentLocation() -> CLLocation? {
        if isTestModeEnabled {
            return forcedTestLocation
        }

        // First try the published location (most recent)
        if let loc = location {
            return loc
        }
        // Fall back to CLLocationManager's last known location
        return locationManager.location
    }

    // MARK: - Path recording (round-scoped)

    /// Begin capturing path samples for upload to `round_altitude_readings`.
    /// Starts the barometer if available so subsequent location updates
    /// carry a paired relative-altitude reading. Wipes any prior in-memory
    /// path so the breadcrumb trail UI starts fresh for this round.
    /// `holeNumberProvider` is invoked on each sample append — typically a
    /// closure that reads `currentRound.currentHole.number` from the
    /// platform DataStore.
    func startPathRecording(roundId: UUID,
                            userId: String,
                            holeNumberProvider: @escaping () -> Int) {
        recordingContext = RecordingContext(
            roundId: roundId,
            userId: userId,
            holeNumberProvider: holeNumberProvider
        )
        pathSamples = []
        // First-tee sync hold: run full fidelity until the elevation
        // calibration gets its first solid sync, the round's first hole
        // is played through, or the current hole has no history to sync
        // against (all released by ElevationReadout). No time cap.
        // Subsequent holes re-sync at each green instead.
        elevationSyncHoldActive = true
        teeHoldActive = true
        setGPSPowerMode(.full)
        // Drain any rows left over from a prior aborted session before
        // starting fresh — they belong to the previous round but the
        // server doesn't care, the row payload carries its own round_id.
        loadPathQueueFromDisk()
        startAltimeter()
        // Bulk-flush every 30s while the round is active. Final flush
        // happens in stopPathRecording.
        uploadFlushTimer?.invalidate()
        uploadFlushTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.flushPathUploads()
        }
        dprint("[LocationManager] Path recording started for round \(roundId)")
        ClientEventLogger.log("altitude.recording.started", detail: [
            "roundId": .string(roundId.uuidString),
            "altimeterAvailable": .bool(CMAltimeter.isRelativeAltitudeAvailable()),
            "testMode": .bool(isTestModeEnabled),
            "diskQueueCarryover": .integer(pendingUploadRows.count)
        ])
    }

    /// Stop capturing. Drains the pending queue (chunked, retrying on
    /// network failure) before returning. Altimeter spins down once the
    /// drain completes. In-memory `pathSamples` stays around until the
    /// next round starts (UI may still want to render the trail
    /// post-round).
    ///
    /// Async because the final drain can take a few seconds over flaky
    /// cell — callers (DataStore.endRound, WatchDataStore.endRound) fire
    /// it inside a Task so the UI doesn't block.
    func stopPathRecording() async {
        guard recordingContext != nil else { return }
        let totalSamples = pathSamples.count
        let pendingAtStop = pendingUploadRows.count
        // Stop the timer first — we don't want it firing concurrent
        // flushes against the same queue while we're draining.
        uploadFlushTimer?.invalidate()
        uploadFlushTimer = nil
        // Drain best-effort. Keep flushing until either the queue is
        // empty or a flush fails (no point hammering when offline —
        // the queue stays on disk and the next round picks it up).
        var drainAttempts = 0
        while !pendingUploadRows.isEmpty && drainAttempts < 40 {
            drainAttempts += 1
            let ok = await flushOneChunk()
            if !ok { break }
        }
        recordingContext = nil
        elevationSyncHoldActive = false
        teeHoldActive = false
        stopAltimeter()
        dprint("[LocationManager] Path recording stopped")
        ClientEventLogger.log("altitude.recording.stopped", detail: [
            "totalSamples": .integer(totalSamples),
            "pendingFlushedAtStop": .integer(pendingAtStop),
            "remainingOnDisk": .integer(pendingUploadRows.count)
        ])
    }

    /// Kicked by the 30s timer. Fires one chunked flush and, if there's
    /// still backlog AND the flush succeeded, schedules another so we
    /// drain quickly when network returns instead of waiting another
    /// 30s per chunk.
    private func flushPathUploads() {
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.flushOneChunk()
            // If we just succeeded and there's more queued, fire again
            // immediately. Bounded by the queue size; no risk of
            // hot-looping because each chunk takes a full HTTP RTT.
            if ok && !self.pendingUploadRows.isEmpty {
                _ = await self.flushOneChunk()
            }
        }
    }

    /// Send up to `pathUploadChunkSize` rows in one PostgREST insert.
    /// Returns true on success, false on any failure (network, auth,
    /// payload). Failed rows are re-prepended to the queue and the
    /// disk copy is rewritten to match.
    @discardableResult
    private func flushOneChunk() async -> Bool {
        // Take a chunk under the lock so we don't race with a
        // concurrent appendPathSample.
        pathQueueLock.lock()
        if pathFlushInFlight {
            // Reclaim a wedged flag: if the in-flight request hung past the
            // deadline (its await never resumed), assume it dead and take
            // over. The upload is an ignore-duplicates upsert on client-side
            // ids, so a zombie request that lands later is harmless.
            if let started = pathFlushStartedAt,
               Date().timeIntervalSince(started) > pathFlushStaleSeconds {
                dprint("[LocationManager] Reclaiming wedged path flush (held \(Int(Date().timeIntervalSince(started)))s)")
            } else {
                pathQueueLock.unlock(); return true // someone else has it
            }
        }
        guard !pendingUploadRows.isEmpty else {
            pathFlushInFlight = false
            pathFlushStartedAt = nil
            pathQueueLock.unlock()
            return true
        }
        pathFlushInFlight = true
        pathFlushStartedAt = Date()
        let chunkCount = min(pathUploadChunkSize, pendingUploadRows.count)
        let chunk = Array(pendingUploadRows.prefix(chunkCount))
        pendingUploadRows.removeFirst(chunkCount)
        savePathQueueLocked()
        pathQueueLock.unlock()

        do {
            let json = try JSONSerialization.data(withJSONObject: chunk)
            let anyJson = try JSONDecoder().decode(AnyJSON.self, from: json)
            // Hard 30s cap on the request. URLSession's own timeout didn't
            // save the 2026-07-05 round — the await simply never resumed —
            // so race the upload against a deadline and treat a loss as a
            // normal failure (requeue + retry next tick). Rows carry
            // client-side UUIDs and go up as ignore-duplicates upserts, so
            // a timed-out request that lands server-side anyway can't make
            // the retry fail with a conflict.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await SupabaseManager.shared.from("round_altitude_readings")
                        .upsert(anyJson, onConflict: "id", ignoreDuplicates: true)
                        .execute()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    throw PathFlushTimeoutError()
                }
                try await group.next()
                group.cancelAll()
            }
            dprint("[LocationManager] Uploaded \(chunk.count) altitude readings")
            ClientEventLogger.log("altitude.flush.ok", detail: [
                "rowCount": .integer(chunk.count),
                "remaining": .integer(pendingUploadRows.count)
            ])
            pathQueueLock.lock(); pathFlushInFlight = false; pathFlushStartedAt = nil; pathQueueLock.unlock()
            return true
        } catch {
            // Put the chunk back at the front and persist again so the
            // next attempt picks it up. Disk copy now reflects the
            // requeued state.
            pathQueueLock.lock()
            pendingUploadRows.insert(contentsOf: chunk, at: 0)
            savePathQueueLocked()
            pathFlushInFlight = false
            pathFlushStartedAt = nil
            pathQueueLock.unlock()
            dprint("[LocationManager] Altitude upload failed (\(chunk.count) rows requeued): \(error)")
            ClientEventLogger.log("altitude.flush.failed", detail: [
                "rowCount": .integer(chunk.count),
                "remaining": .integer(pendingUploadRows.count),
                "error": .string(String(describing: error).prefix(200).description)
            ])
            return false
        }
    }

    private func startAltimeter() {
        guard !altimeterRunning else { return }
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            dprint("[LocationManager] Barometer unavailable — altitude readings will be nil")
            return
        }
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            let v = data.relativeAltitude.doubleValue
            self.latestRelativeAltitudeMeters = v
            if self.pathAltWindow.count < self.pathAltWindowCap {
                self.pathAltWindow.append(v)
            }
        }
        altimeterRunning = true
    }

    private func stopAltimeter() {
        guard altimeterRunning else { return }
        altimeter.stopRelativeAltitudeUpdates()
        altimeterRunning = false
        latestRelativeAltitudeMeters = nil
        pathAltWindow.removeAll()
    }

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

/// Thrown when a path-upload request exceeds its deadline — treated as a
/// normal flush failure so the chunk requeues and the in-flight flag clears.
private struct PathFlushTimeoutError: Error {}

extension LocationManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        dprint("[LocationManager] Authorization changed to: \(authorizationStatus.rawValue)")

        #if os(iOS) || os(watchOS)
        let authorized = authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
        #elseif os(macOS)
        let authorized = authorizationStatus == .authorizedAlways
        #endif

        if authorized {
            dprint("[LocationManager] Authorization granted, starting location tracking")
            startTracking()
        } else if authorizationStatus == .denied || authorizationStatus == .restricted {
            dprint("[LocationManager] Authorization denied or restricted")
            errorMessage = "Location access denied. Please enable in Settings."
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if isTestModeEnabled {
            location = forcedTestLocation
            errorMessage = nil
            return
        }

        guard let newLocation = locations.last else { return }
        dprint("[LocationManager] Got location update: \(newLocation.coordinate.latitude), \(newLocation.coordinate.longitude)")
        location = newLocation
        appendPathSample(newLocation)
        locationPublisher.send(newLocation)
        errorMessage = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // Written to `compass`, not `heading` — see `Compass` for why.
        // Test mode keeps the real compass: the simulated position is fake,
        // but which way the wrist faces is still real.
        guard newHeading.headingAccuracy >= 0 else {
            compass.degrees = nil
            return
        }
        // Use true heading if available, otherwise use magnetic heading
        compass.degrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if isTestModeEnabled {
            return
        }
        errorMessage = "Failed to get location: \(error.localizedDescription)"
    }
}
