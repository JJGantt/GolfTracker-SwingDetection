import Foundation
import CoreMotion
import CoreLocation
import Combine
import WatchKit
import WatchConnectivity
import StrokeSaverAlgorithms
import Supabase

// Detection mode enum
enum DetectionMode: String, CaseIterable {
    case off = "Off"
    case unifDetect = "Unif"
}

// Preset for unifDetect params
enum UnifDetectPreset: String, CaseIterable {
    case permissive = "Permissive"
    case restrictive = "Restrictive"
    case custom = "Custom"
}

class SwingDetectionManager: NSObject, ObservableObject {
    static let shared = SwingDetectionManager()

    let motionManager = CMMotionManager()
    let locationManager = LocationManager.shared
    let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        return q
    }()
    var extendedSession: WKExtendedRuntimeSession?

    @Published var lastDetectedSwing: DetectedSwing?
    @Published var isMonitoring: Bool = false

    // User Acceleration (gravity removed)
    @Published var userAccelMag: Double = 0.0
    @Published var userAccelX: Double = 0.0
    @Published var userAccelY: Double = 0.0
    @Published var userAccelZ: Double = 0.0

    // Rotation Rate (gyroscope)
    @Published var rotationMag: Double = 0.0
    @Published var rotationX: Double = 0.0
    @Published var rotationY: Double = 0.0
    @Published var rotationZ: Double = 0.0

    // Gravity vector
    @Published var gravityX: Double = 0.0
    @Published var gravityY: Double = 0.0
    @Published var gravityZ: Double = 0.0

    // Attitude (orientation)
    @Published var pitch: Double = 0.0
    @Published var roll: Double = 0.0
    @Published var yaw: Double = 0.0

    // Detection mode and parameters
    @Published var detectionMode: DetectionMode = .unifDetect {
        didSet {
            UserDefaults.standard.set(detectionMode.rawValue, forKey: "swingDetectionMode")
            updateRawAccelForCapture()
        }
    }

    // MARK: - Unif Detect (single detector, tri-state classification)

    lazy var unifiedDetector: UnifiedDetector = {
        // The detector reports its diagnostic-tier events through this sink;
        // they land in `client_events` behind the diagnostics toggle.
        AlgorithmLog.diagnosticSink = { event, detail in
            ClientEventLogger.log(event, level: .diagnostic, detail: detail?.mapValues { $0.anyJSON })
        }
        let d = UnifiedDetector()
        d.log = { msg in dprint("⌚ \(msg)") }
        return d
    }()

    // Contact requirement toggle (putts: 800Hz raw accel, swings: rotX spike)
    /// When ON, paired shape events go through the full post-pairing gate
    /// stage (contact quality + timing + dynamics + smoothness) before
    /// firing as detections. When OFF, paired shapes fire immediately —
    /// useful for development to isolate pairing-stage misses from
    /// gate-stage misses. Persisted in UserDefaults under
    /// `requirePostPairingGates`. Not user-facing today (no UI binding).
    @Published var requirePostPairingGates: Bool = true {
        didSet {
            UserDefaults.standard.set(requirePostPairingGates, forKey: "requirePostPairingGates")
        }
    }

    // Auto-add: detected swings are automatically added as strokes
    @Published var autoAdd: Bool = true {
        didSet { UserDefaults.standard.set(autoAdd, forKey: "autoAdd") }
    }

    // Practice swing replacement: when enabled, consecutive swing detections at the same
    // location replace the previous auto-added stroke instead of adding a new one.
    // Only applies to swings (not putts, since putting proximity makes GPS unreliable).
    @Published var ignorePractice: Bool = true {
        didSet { UserDefaults.standard.set(ignorePractice, forKey: "ignorePractice") }
    }
    @Published var ignorePracticeRadius: Double = 10.0 {  // yards
        didSet { UserDefaults.standard.set(ignorePracticeRadius, forKey: "ignorePracticeRadius") }
    }

    // Auto-select putter on putt detection within this distance (yards). 0 = disabled.
    @Published var puttAutoSelectYards: Int = 25 {
        didSet { UserDefaults.standard.set(puttAutoSelectYards, forKey: "puttAutoSelectYards") }
    }

    // GPS switches to moderate accuracy above this distance (yards). 0 = always full.
    @Published var gpsModerateYards: Int = 200 {
        didSet { UserDefaults.standard.set(gpsModerateYards, forKey: "gpsModerateYards") }
    }

    // Club awareness
    @Published var selectedClubTypeName: String? = nil
    var isPutterSelected: Bool {
        selectedClubTypeName == "Putt"
    }

    // MARK: - 800Hz stream liveness
    //
    // The batched-sensor stream can die silently mid-session: on 2026-08-31 it
    // stopped 3.5 minutes into a session, every later detection reported the
    // stream as armed, and 46 of 54 events uploaded with no vibration data —
    // with the only trace a local console line nobody can see. `armed` (the
    // flags) and `alive` (samples actually arriving) are different facts, so
    // liveness is measured from delivery: a batch arrives ~every 0.5s, so
    // armed-and-silent for >2s is DOWN. Transitions are logged to the server
    // at lifecycle level and published for the Swing Test screen.
    enum Raw800State { case off, live, down }
    @Published var raw800State: Raw800State = .off
    @Published var raw800DownSince: Date? = nil
    var lastRawBatchWall: Date? = nil
    private var raw800DownLogged = false
    private var lastRawLivenessCheck: TimeInterval = 0
    /// Watchdog restarts since the last delivered batch, and the earliest the
    /// next one may run. Backoff doubles from 2s to a 60s ceiling so a sensor
    /// that will not come back costs one restart a minute, not a busy loop.
    private var raw800RestartAttempts = 0
    private var raw800NextRestartAt: Date? = nil

    /// Called from the batch-delivery loop (~2Hz). Marks the stream live and
    /// closes out a logged outage.
    func noteRawBatchArrived() {
        let now = Date()
        lastRawBatchWall = now
        raw800RestartAttempts = 0
        raw800NextRestartAt = nil
        if raw800DownLogged {
            let downFor = raw800DownSince.map { now.timeIntervalSince($0) } ?? 0
            ClientEventLogger.log("rawAccel.stream.up", detail: [
                "downSeconds": .double(downFor)
            ])
            raw800DownLogged = false
        }
        DispatchQueue.main.async {
            if self.raw800State != .live { self.raw800State = .live }
            self.raw800DownSince = nil
        }
    }

    /// The stream was just (re)started. Silence is measured from here. It was
    /// measured from the last batch of whatever ran before, so every restart
    /// logged a phantom outage spanning the whole gap — 41 of the 42
    /// `stream.down` rows on 2026-09-07 were that, not real dropouts.
    func noteRawStreamArmed() {
        lastRawBatchWall = Date()
    }

    /// Called from the 100Hz motion tick, throttled to ~1Hz. Detects
    /// running-but-silent, logs the DOWN transition once, and restarts the
    /// stream with backoff until batches flow again.
    func checkRaw800Liveness(sensorTime: TimeInterval) {
        guard sensorTime - lastRawLivenessCheck >= 1.0 else { return }
        lastRawLivenessCheck = sensorTime
        guard isBatchedAccelRunning else {
            if raw800State != .off { DispatchQueue.main.async { self.raw800State = .off } }
            return
        }
        guard let last = lastRawBatchWall else { return }
        let silent = Date().timeIntervalSince(last)
        guard silent > 2.0 else { return }
        if !raw800DownLogged {
            raw800DownLogged = true
            ClientEventLogger.log("rawAccel.stream.down", detail: [
                "silentSeconds": .double(silent)
            ])
            DispatchQueue.main.async {
                self.raw800State = .down
                self.raw800DownSince = last
            }
        }
        // Watchdog. Nothing else ever restarts a stream that dies while it is
        // meant to be running — the 2026-08-31 outage sat dead for 35 minutes.
        let now = Date()
        if let next = raw800NextRestartAt, now < next { return }
        raw800RestartAttempts += 1
        let backoff = min(60.0, 2.0 * pow(2.0, Double(raw800RestartAttempts - 1)))
        raw800NextRestartAt = now.addingTimeInterval(backoff)
        ClientEventLogger.log("rawAccel.stream.restart", detail: [
            "attempt": .integer(raw800RestartAttempts),
            "silentSeconds": .double(silent),
            "nextRetrySeconds": .double(backoff),
            "canStart": .bool(canStartRawAccelNow)
        ])
        restartRawAccel()
    }

    // Published: true briefly when 800Hz raw accel confirms ball contact after a shape detection
    @Published var contactConfirmedRecently: Bool = false

    // Pending unified shape events waiting for 100Hz DM contact check (protected by eventsLock)
    var pendingUnifShapes: [UnifiedShapeEvent] = []

    /// Rejected shapes accumulating since the last successful stroke.
    /// When the user manually adds a stroke, EVERY entry in this buffer
    /// is uploaded as a `false_negative` — the user only manually adds
    /// when they actually swung, and any rejected shape between strokes
    /// is by definition a real motion the detector caught at the shape
    /// level but the contact gate killed. The buffer is cleared on every
    /// stroke (manual or auto) so the next inter-stroke window starts
    /// empty.
    ///
    /// Why no time cap: between strokes the user is in "actively trying
    /// to swing" mode. All rejections in that window are likely related
    /// to swing attempts. Time-based decay would drop the false-negatives
    /// from longer setup periods (warm-ups, putt re-aims).
    struct RejectedShape {
        let shape: UnifiedShapeEvent
        let gate: PostPairingGateResult
        let motionSlice: [RecordedDataPoint]
        let rawAccelSlice: [RawAccelDataPoint]
        let rejectedAt: Date
        let stage: String  // "DM" (100Hz) or "raw800"
    }
    var rejectedShapesSinceLastStroke: [RejectedShape] = []

    /// Called by PostPairingGates when a shape is rejected outright (DM
    /// gate failed and 800Hz isn't running, or 800Hz override also failed).
    /// Captures the same motion + raw accel slices we'd ship for a real
    /// detection, plus the gate result with `fails` populated.
    func recordRejection(shape: UnifiedShapeEvent, gate: PostPairingGateResult, stage: String) {
        let motionWindowStart = shape.bsTopT - 2.0
        let motionWindowEnd = shape.fsPeakT + 1.0
        rollingBufferLock.lock()
        let motionSlice = rollingMotionBuffer.filter {
            $0.sensorTime >= motionWindowStart && $0.sensorTime <= motionWindowEnd
        }
        rollingBufferLock.unlock()
        eventBufferLock.lock()
        let rawAccelSlice = eventRawAccelBuffer.samples(in: motionWindowStart...motionWindowEnd)
        eventBufferLock.unlock()

        rejectedShapesSinceLastStroke.append(RejectedShape(
            shape: shape, gate: gate,
            motionSlice: motionSlice, rawAccelSlice: rawAccelSlice,
            rejectedAt: Date(), stage: stage
        ))
    }

    /// Pops and returns ALL rejected shapes accumulated since the last
    /// stroke. Clears the buffer. Used by the manual-stroke-add path to
    /// upload every recent rejection as a false-negative.
    func claimAllRejectionsSinceLastStroke() -> [RejectedShape] {
        let claimed = rejectedShapesSinceLastStroke
        rejectedShapesSinceLastStroke.removeAll()
        return claimed
    }

    /// Discards the buffer without uploading. Used by the auto-detect
    /// success path — when the system DID catch a swing, intermediate
    /// rejections are noise, not missed swings.
    func clearRejectionsSinceLastStroke() {
        rejectedShapesSinceLastStroke.removeAll()
    }

    // MARK: - Lookback Capture

    /// True while Swing Test Mode owns the detector. Read by
    /// `fireSmartDetection` so a detection is not discarded for want of a GPS
    /// fix, which test mode frequently has none of.
    @Published var testModeActive: Bool = false

    /// Sensor time up to which motion is already accounted for — by a fired
    /// detection or by an earlier lookback capture. A capture never reaches
    /// back past this, so pressing the button twice cannot upload the same
    /// swing twice, and a capture following a real detection contains only the
    /// motion since that detection.
    private var lastCaptureBoundarySensorTime: TimeInterval = 0

    /// Longest window a single lookback will reach back over.
    static let lookbackMaxSeconds: TimeInterval = 15.0

    /// How long to wait before re-slicing the 800Hz ring for upload. Batches
    /// arrive about every 0.5s, so this must clear a couple of them plus the
    /// 0.3s of post-impact window the contact gate reads.
    let rawAccelSettleDelay: TimeInterval = 2.5

    struct LookbackCapture {
        let motionSlice: [RecordedDataPoint]
        let rawAccelSlice: [RawAccelDataPoint]
        let rejections: [RejectedShape]
        let windowSeconds: Double
        /// Kept so the 800Hz can be re-sliced for the same span once the
        /// batches covering it have landed — see `rawAccelSlice(from:to:)`.
        let windowStart: TimeInterval
        let windowEnd: TimeInterval
    }

    /// Re-read the 800Hz ring for an already-decided window. Used after
    /// `rawAccelSettleDelay` so a capture is not stored missing the batch that
    /// carried the impact.
    func rawAccelSlice(from: TimeInterval, to: TimeInterval) -> [RawAccelDataPoint] {
        eventBufferLock.lock()
        defer { eventBufferLock.unlock() }
        return eventRawAccelBuffer.samples(in: from...to)
    }

    /// Called on every fired detection to advance the boundary. Motion up to
    /// here has an event of its own and must not be re-captured.
    func markCaptureBoundary() {
        lastCaptureBoundarySensorTime = lastDeviceMotionSensorTime
    }

    /// Grab the raw motion window for a swing the detector said nothing about.
    ///
    /// The window ends now and starts at the later of (now − `lookbackMaxSeconds`)
    /// and the last boundary, so it shrinks automatically to cover only ground
    /// nothing has claimed yet — often well under the maximum. Any rejections
    /// inside it come along, and an empty rejection list is the informative
    /// case: the swing never even paired.
    ///
    /// Returns nil when the window is empty, which means the boundary is
    /// already at "now" — a detection just fired, or the button was already
    /// pressed and there is nothing new to send.
    func captureLookbackWindow() -> LookbackCapture? {
        let windowEnd = lastDeviceMotionSensorTime
        let windowStart = max(windowEnd - Self.lookbackMaxSeconds, lastCaptureBoundarySensorTime)
        guard windowEnd > windowStart else {
            ClientEventLogger.log("lookback.capture.empty", detail: [
                "windowEnd": .double(windowEnd),
                "boundary": .double(lastCaptureBoundarySensorTime)
            ])
            return nil
        }

        rollingBufferLock.lock()
        let motionSlice = rollingMotionBuffer.filter {
            $0.sensorTime >= windowStart && $0.sensorTime <= windowEnd
        }
        rollingBufferLock.unlock()

        eventBufferLock.lock()
        let rawAccelSlice = eventRawAccelBuffer.samples(in: windowStart...windowEnd)
        eventBufferLock.unlock()

        let inWindow = rejectedShapesSinceLastStroke.filter {
            $0.shape.fsPeakT >= windowStart && $0.shape.fsPeakT <= windowEnd
        }
        // Consume them — they're attached to this capture now, and in test
        // mode there is no stroke to otherwise drain the buffer.
        rejectedShapesSinceLastStroke.removeAll {
            $0.shape.fsPeakT >= windowStart && $0.shape.fsPeakT <= windowEnd
        }

        lastCaptureBoundarySensorTime = windowEnd

        ClientEventLogger.log("lookback.capture", detail: [
            "windowSeconds": .double(windowEnd - windowStart),
            "motionSamples": .integer(motionSlice.count),
            "rawAccelSamples": .integer(rawAccelSlice.count),
            "rejections": .integer(inWindow.count)
        ])

        return LookbackCapture(
            motionSlice: motionSlice,
            rawAccelSlice: rawAccelSlice,
            rejections: inWindow,
            windowSeconds: windowEnd - windowStart,
            windowStart: windowStart,
            windowEnd: windowEnd
        )
    }
    // Shapes that failed the 100Hz DM check but may be overridden by 800Hz raw accel (putter mode)
    var pendingUnifShapesDMFailed: [UnifiedShapeEvent] = []
    let eventsLock = NSLock()

    // Staleness tracking for expireStaleTVShapes (defined in +PostPairingGates)
    var lastStaleCheckTime: TimeInterval = 0
    var rawAccelMissingWarned = false

    /// Most recent raw accel sample timestamp. Written on rawAccelQueue, read on motionQueue.
    /// arm64 Double reads/writes are atomic — safe without a lock.
    var latestRawAccelTime: TimeInterval = 0

    struct DetectionMetadata {
        var strokeId: UUID?
        let timestamp: Date
        let swingType: SwingType
        let classification: StrokeClassification

        // Setup
        let setupStartT: TimeInterval
        let setupEndT: TimeInterval
        let setupDuration: TimeInterval

        // BS Top
        let bsTopT: TimeInterval
        let bsClassification: StrokeClassification
        let bsRotMag: Double
        let bsProminence: Double
        let bsPeakRotX, bsPeakRotY, bsPeakRotZ: Double
        let bsTopPitch, bsTopRoll: Double
        let bsAreaBeforeX, bsAreaBeforeY, bsAreaBeforeZ: Double
        let bsAreaAfterX, bsAreaAfterY, bsAreaAfterZ: Double

        // FS Peak
        let fsPeakT: TimeInterval
        let fsClassification: StrokeClassification
        let fsPeakRotMag: Double
        let fsProminence: Double
        let fsPeakRotX, fsPeakRotY, fsPeakRotZ: Double
        let fsAreaBeforeX, fsAreaBeforeY, fsAreaBeforeZ: Double
        let fsAreaAfterX, fsAreaAfterY, fsAreaAfterZ: Double

        // Derived
        let fsBsRatio: Double
        let peakAcceleration: Double
        let preStrokePitch, preStrokeRoll: Double

        // Post-pairing gate values (nil if requirePostPairingGates was off)
        let contactTV: Double?
        let contactN: Int?
        let contactTVX, contactTVY, contactTVZ: Double?
        let extremaSpread: Double?
        let baselineTV: Double?
        let baselineN: Int?

        // Location
        let latitude, longitude: Double
        let trajectoryHeading: Double?
    }

    var detectionMetadataCache: [UUID: DetectionMetadata] = [:]
    var detectionMotionCache: [UUID: [RecordedDataPoint]] = [:]
    private(set) var lastDetectionMetadata: DetectionMetadata?
    var lastDetectionMotionSlice: [RecordedDataPoint] = []
    /// The swing_events row id of the most recent auto-add upload. Set by
    /// `fireSmartDetection` after the synchronous-returned id from
    /// `SupabaseUploader.onSwingDetected`. The auto-add UI flow reads this
    /// to pair the stroke with its event (for false-positive marking on
    /// undo). Nil when the most recent detection was manual (no immediate
    /// upload — pending lifecycle handles labeling there).
    var lastSwingEventId: UUID?

    struct RecordedDataPoint: Codable {
        let sensorTime: TimeInterval
        let userAccelX: Double
        let userAccelY: Double
        let userAccelZ: Double
        let userAccelMag: Double
        let rotationX: Double
        let rotationY: Double
        let rotationZ: Double
        let rotationMag: Double
        let gravityX: Double
        let gravityY: Double
        let gravityZ: Double
        let pitch: Double
        let roll: Double
        let yaw: Double
        // CMMagneticField.accuracy at this sample. Used downstream to filter
        // swings whose magnetometer-anchored attitude can't be trusted (e.g.
        // metallic interference, uncalibrated cold start). Values:
        //   -1 = uncalibrated (sensor not yet usable)
        //    0 = low      (large error possible)
        //    1 = medium
        //    2 = high     (best quality)
        let magAccuracy: Int
    }

    // Raw accelerometer data point (high frequency, only during recording)
    struct RawAccelDataPoint: Codable {
        let sensorTime: TimeInterval
        let rawAccelX: Double
        let rawAccelY: Double
        let rawAccelZ: Double
        let rawAccelMag: Double
    }

    /// Fixed-capacity time-ordered ring buffer for high-rate raw accel samples.
    struct RawAccelRingBuffer {
        private var storage: [RawAccelDataPoint?]
        private var head: Int = 0
        private(set) var count: Int = 0

        init(capacity: Int) {
            let cap = max(1, capacity)
            storage = Array(repeating: nil, count: cap)
        }

        mutating func clear() {
            head = 0
            count = 0
        }

        mutating func append(_ sample: RawAccelDataPoint) {
            storage[head] = sample
            head = (head + 1) % storage.count
            if count < storage.count {
                count += 1
            }
        }

        mutating func trim(olderThan cutoff: TimeInterval) {
            while count > 0 {
                let oldestIndex = (head - count + storage.count) % storage.count
                guard let oldest = storage[oldestIndex] else {
                    count -= 1
                    continue
                }
                if oldest.sensorTime < cutoff {
                    storage[oldestIndex] = nil
                    count -= 1
                } else {
                    break
                }
            }
            if count == 0 {
                head = 0
            }
        }

        func samples(in range: ClosedRange<TimeInterval>) -> [RawAccelDataPoint] {
            guard count > 0 else { return [] }
            var out: [RawAccelDataPoint] = []
            out.reserveCapacity(min(count, 512))
            for offset in 0..<count {
                let idx = (head - count + offset + storage.count) % storage.count
                guard let sample = storage[idx] else { continue }
                let t = sample.sensorTime
                if t < range.lowerBound {
                    continue
                }
                if t > range.upperBound {
                    break
                }
                out.append(sample)
            }
            return out
        }
    }

    let rawAccelQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        return q
    }()

    // CMBatchedSensorManager — 800 Hz raw accelerometer
    let batchedSensorManager = CMBatchedSensorManager()
    var batchedAccelTask: Task<Void, Never>?
    var isBatchedAccelRunning = false
    var isUsingFallbackRawAccel = false
    /// Serializes every 800Hz start and stop — see `startRawAccelLocked`.
    let rawAccelControlLock = NSLock()

    // Core Motion authorization
    @Published var motionAuthStatus: CMAuthorizationStatus = .notDetermined
    @Published var rawAccelAuthOK: Bool = true
    private let activityManager = CMMotionActivityManager()

    // Pedometer — counts steps since the last detected swing. Published
    // so the watch can render a small live debug readout. Reset to 0
    // every time `fireSmartDetection` runs (a real detection fires).
    private let pedometer = CMPedometer()
    @Published var stepsSinceLastDetectedSwing: Int = 0
    private var pedometerStartDate: Date = Date()
    private var pedometerStartedMonitoring = false

    /// Step-count gate threshold used by the practice-shot dedup logic.
    /// Read live from UserDefaults so the iOS dev settings slider can tune
    /// it. Default 10. Set arbitrarily high to disable the gate.
    static let stepGateThresholdKey = "practiceStepGateThreshold"
    var stepGateThreshold: Int {
        let v = UserDefaults.standard.integer(forKey: Self.stepGateThresholdKey)
        return v > 0 ? v : 10
    }

    func startPedometerMonitoring() {
        guard !pedometerStartedMonitoring else { return }
        guard CMPedometer.isStepCountingAvailable() else { return }
        pedometerStartedMonitoring = true
        pedometerStartDate = Date()
        pedometer.startUpdates(from: pedometerStartDate) { [weak self] data, _ in
            guard let self = self, let data = data else { return }
            let steps = data.numberOfSteps.intValue
            DispatchQueue.main.async { self.stepsSinceLastDetectedSwing = steps }
        }
    }

    func stopPedometerMonitoring() {
        guard pedometerStartedMonitoring else { return }
        pedometerStartedMonitoring = false
        pedometer.stopUpdates()
        DispatchQueue.main.async { self.stepsSinceLastDetectedSwing = 0 }
    }

    /// Reset the step counter — called from `fireSmartDetection` so each
    /// detected swing starts a fresh inter-swing step-tally window.
    func resetStepsSinceLastDetectedSwing() {
        guard pedometerStartedMonitoring else { return }
        pedometer.stopUpdates()
        pedometerStartDate = Date()
        DispatchQueue.main.async { self.stepsSinceLastDetectedSwing = 0 }
        pedometer.startUpdates(from: pedometerStartDate) { [weak self] data, _ in
            guard let self = self, let data = data else { return }
            let steps = data.numberOfSteps.intValue
            DispatchQueue.main.async { self.stepsSinceLastDetectedSwing = steps }
        }
    }

    // HKWorkoutSession ownership
    private var monitoringStartedWorkout = false

    // Latest device-motion timestamp seen on motionQueue.
    var lastDeviceMotionSensorTime: TimeInterval = 0

    // Swing detection parameters
    private let updateInterval: TimeInterval = 0.01 // 100 Hz device motion

    // Event capture — circular buffer for 800Hz raw accel around detected swings.
    //
    // Sized to `lookbackMaxSeconds`, not to a detection window, because the
    // Missed It button reaches back that far. At the previous 5s a 15s lookback
    // could only ever recover the last third of itself: a putt more than ~5s
    // before the press had its 800Hz already rolled out of the ring while the
    // 100Hz motion (180s) survived intact, so a window could show three setups
    // and carry no contact data at all. Measured fragments were 0.5-2.5s, and
    // the contact gate spans bsTop→fsPeak+0.3s (~0.6-1.0s), so the short end
    // did not even cover the stroke.
    //
    // ~12,000 samples ≈ 480 KB. Retention costs memory, not battery — the drain
    // is in running the sensor, not in keeping what it produced.
    static let eventRawRingCapacity = 12_800   // 16s @ 800Hz, margin for burstiness
    var eventRawAccelBuffer = RawAccelRingBuffer(capacity: eventRawRingCapacity)
    let eventBufferDuration: TimeInterval = SwingDetectionManager.lookbackMaxSeconds
    var rawAccelRunningForCapture: Bool = false
    let eventBufferLock = NSLock()

    // Rolling buffer — 3 min at 100Hz = 18,000 samples (~660KB)
    var rollingMotionBuffer: [RecordedDataPoint] = []
    let rollingBufferDuration: TimeInterval = 180.0
    let rollingBufferLock = NSLock()


    struct DetectedSwing {
        let location: CLLocationCoordinate2D
        let timestamp: Date
        let peakAcceleration: Double
        let trajectoryHeading: Double?
        let swingType: SwingType
        let fsPeakRotMag: Double
        let fsBsRatio: Double
        let bsTopPitch: Double
        let bsTopRoll: Double
        let preStrokePitch: Double
        let preStrokeRoll: Double
        let bsPeakRotX: Double
        let bsPeakRotY: Double
        let bsPeakRotZ: Double
        let bsPeakRotMag: Double
        let fsPeakRotX: Double
        let fsPeakRotY: Double
        let fsPeakRotZ: Double
    }

    private override init() {
        super.init()
        // Load persisted detection mode (before setupMotionManager)
        if let modeString = UserDefaults.standard.string(forKey: "swingDetectionMode"),
           let mode = DetectionMode(rawValue: modeString) {
            detectionMode = mode
        }
        if UserDefaults.standard.object(forKey: "requirePostPairingGates") != nil {
            requirePostPairingGates = UserDefaults.standard.bool(forKey: "requirePostPairingGates")
        }
        if UserDefaults.standard.object(forKey: "autoAdd") != nil {
            autoAdd = UserDefaults.standard.bool(forKey: "autoAdd")
        }
        if UserDefaults.standard.object(forKey: "ignorePractice") != nil {
            ignorePractice = UserDefaults.standard.bool(forKey: "ignorePractice")
        }
        if UserDefaults.standard.object(forKey: "ignorePracticeRadius") != nil {
            ignorePracticeRadius = UserDefaults.standard.double(forKey: "ignorePracticeRadius")
        }
        if UserDefaults.standard.object(forKey: "puttAutoSelectYards") != nil {
            puttAutoSelectYards = UserDefaults.standard.integer(forKey: "puttAutoSelectYards")
        }
        if UserDefaults.standard.object(forKey: "gpsModerateYards") != nil {
            gpsModerateYards = UserDefaults.standard.integer(forKey: "gpsModerateYards")
        }
        setupMotionManager()
        checkAndRequestMotionAuthorization()
    }

    // MARK: - Unif Detect Presets

    // The preset system is gone. `applyUnifPreset` assigned a literal to every
    // gate, which made it a competing source of truth the moment `detector_config`
    // became authoritative — a preset applied after a load would have silently
    // overwritten the tuned values with numbers compiled into the build. Presets
    // also solved a problem that no longer exists: switching several thresholds
    // at once without a build. The algorithms repo's `swing_detection/tune.py` does that against the
    // table, for any subset, without shipping anything.

    private func setupMotionManager() {
        guard motionManager.isDeviceMotionAvailable else {
            dprint("⌚ [SwingDetection] Device Motion not available")
            return
        }
        motionManager.deviceMotionUpdateInterval = updateInterval
    }

    func checkAndRequestMotionAuthorization() {
        let status = CMMotionActivityManager.authorizationStatus()
        DispatchQueue.main.async { self.motionAuthStatus = status }

        switch status {
        case .authorized:
            dprint("⌚ [SwingDetection] Core Motion authorized")
        case .notDetermined:
            dprint("⌚ [SwingDetection] Core Motion not determined — triggering system prompt")
            activityManager.startActivityUpdates(to: .main) { _ in }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.activityManager.stopActivityUpdates()
            }
        case .denied, .restricted:
            dprint("⌚ [SwingDetection] Core Motion denied/restricted — show blocking UI")
        @unknown default:
            dprint("⌚ [SwingDetection] Core Motion unknown auth status: \(status.rawValue)")
        }
    }

    func startMonitoring() {
        guard motionManager.isDeviceMotionAvailable else {
            dprint("⌚ [SwingDetection] Cannot start monitoring - device motion not available")
            return
        }

        // Start step counting alongside motion. The published
        // `stepsSinceLastDetectedSwing` powers the live debug readout
        // and the practice-shot gate.
        startPedometerMonitoring()

        guard !isMonitoring else {
            dprint("⌚ [SwingDetection] Already monitoring")
            return
        }

        dprint("⌚ [SwingDetection] Starting swing detection on background queue")
        isMonitoring = true
        rawAccelMissingWarned = false

        // Pull the latest thresholds before the first sample is judged. A failed
        // fetch leaves whatever is already in force (the disk cache), so a
        // dropped connection never moves a gate mid-round.
        Task { @MainActor in
            await DetectorConfig.shared.refresh()
            if !DetectorConfig.shared.isLoaded {
                // Nothing has ever resolved: no network now and nothing cached.
                // Detecting here would judge strokes against the literals the
                // stored properties happen to be declared with, which is not a
                // configuration anyone chose. Say so loudly instead.
                ClientEventLogger.log("detectorConfig.unavailable.detectionDisabled")
                dprint("⌚ [SwingDetection] No detector config — detection disabled")
            }
        }

        // Arm the raw-accel event buffer explicitly.
        //
        // `rawAccelRunningForCapture` gates BOTH starting the 800Hz hardware and
        // whether delivered samples are written to `eventRawAccelBuffer`, yet it
        // was only ever set from two didSets: `detectionMode` (which fires at
        // init only when its UserDefaults key already exists) and
        // `selectedClubTypeName`. Rounds worked by side effect — picking a club
        // set it — so nothing whose club never changed captured a single 800Hz
        // sample. Swing Test Mode selects no club, and its first session
        // uploaded 11 events with rawAccelSampleCount=0: the contact evidence
        // that soft putts most depend on, absent, with no error anywhere.
        // Monitoring starting is the real precondition, so say so here.
        updateRawAccelForCapture()

        if !WorkoutManager.shared.isWorkoutActive {
            monitoringStartedWorkout = true
            WorkoutManager.shared.onSessionRunning = { [weak self] in
                self?.syncRawAccelHardwareState()
            }
            WorkoutManager.shared.requestAuthorization { [weak self] success, error in
                guard let self = self else { return }
                if !success {
                    // Denied share access means the session can never keep the app
                    // alive screen-off. Record it so the capture UI can say so
                    // instead of recording into a stream that will be suspended.
                    DispatchQueue.main.async {
                        WorkoutManager.shared.lastFailure =
                            "HealthKit workout access denied\(error.map { ": \($0.localizedDescription)" } ?? "")"
                    }
                }
                WorkoutManager.shared.startWorkout()
                self.phoneLog("[SwingDetection] requestAuthorization done (success=\(success)) — starting HKWorkoutSession")
            }
        } else {
            phoneLog("[SwingDetection] startMonitoring: HKWorkoutSession already active")
            syncRawAccelHardwareState()
        }

        startExtendedSession()

        // Use magnetic-north-anchored attitude so per-sample yaw is a real
        // compass bearing (in radians from magnetic north, Z = vertical).
        // Default `xArbitraryZVertical` produces yaw relative to whatever
        // direction the watch happened to be facing at app start, which
        // makes the recorded attitude unusable for any world-frame analysis
        // (e.g. swing aim direction). With `xMagneticNorthZVertical`, iOS's
        // sensor-fusion pipeline keeps the gyro-integrated attitude anchored
        // to magnetometer north over time. Falls back gracefully when the
        // magnetometer is uncalibrated — `attitude` is still produced; the
        // calibration accuracy can be inspected via the workout's heading
        // service if we need it.
        motionManager.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: motionQueue) { [weak self] data, error in
            guard let self = self, let data = data else { return }
            self.processDeviceMotion(data)
        }
    }

    func stopMonitoring() {
        guard isMonitoring else { return }

        dprint("⌚ [SwingDetection] Stopping swing detection")
        isMonitoring = false
        stopPedometerMonitoring()
        motionManager.stopDeviceMotionUpdates()
        extendedSession?.invalidate()
        extendedSession = nil
        stopBatchedAccelIfUnneeded()
        if monitoringStartedWorkout {
            WorkoutManager.shared.endWorkout()
            monitoringStartedWorkout = false
            phoneLog("[SwingDetection] stopMonitoring: ended background HKWorkoutSession")
        }
        SupabaseUploader.shared.flushPending()
        rollingBufferLock.lock()
        rollingMotionBuffer.removeAll()
        rollingBufferLock.unlock()
        resetAllDetectors()
    }

    private func processDeviceMotion(_ data: CMDeviceMotion) {
        lastDeviceMotionSensorTime = data.timestamp

        // User Acceleration (gravity removed)
        let uax = data.userAcceleration.x
        let uay = data.userAcceleration.y
        let uaz = data.userAcceleration.z
        let uaMag = sqrt(uax * uax + uay * uay + uaz * uaz)

        // Rotation Rate
        let rx = data.rotationRate.x
        let ry = data.rotationRate.y
        let rz = data.rotationRate.z
        let rMag = sqrt(rx * rx + ry * ry + rz * rz)

        // Gravity
        let gx = data.gravity.x
        let gy = data.gravity.y
        let gz = data.gravity.z

        // Attitude
        let p = data.attitude.pitch
        let r = data.attitude.roll
        let y = data.attitude.yaw

        // Magnetometer accuracy at this sample. iOS exposes this on the
        // device-motion's magnetic-field reading. Mapped to a small integer
        // for compact CSV serialization (-1=uncalibrated, 0=low, 1=med, 2=high).
        let magAcc = data.magneticField.accuracy.rawValue

        // Rolling 3-min buffer — fed continuously while monitoring so the
        // detector can pull motion slices for swing_event uploads.
        if isMonitoring {
            let dp = RecordedDataPoint(
                sensorTime: data.timestamp, userAccelX: uax, userAccelY: uay, userAccelZ: uaz, userAccelMag: uaMag,
                rotationX: rx, rotationY: ry, rotationZ: rz, rotationMag: rMag,
                gravityX: gx, gravityY: gy, gravityZ: gz, pitch: p, roll: r, yaw: y,
                magAccuracy: Int(magAcc)
            )
            rollingBufferLock.lock()
            rollingMotionBuffer.append(dp)
            let cutoff = data.timestamp - rollingBufferDuration
            while let first = rollingMotionBuffer.first, first.sensorTime < cutoff {
                rollingMotionBuffer.removeFirst()
            }
            rollingBufferLock.unlock()
        }

        checkRaw800Liveness(sensorTime: data.timestamp)

        // Detection logic. Gated on a resolved config — see DetectorConfig:
        // the compiled literals exist only to satisfy Swift's initialisation
        // rules and must never be what judges a stroke.
        guard DetectorParameters.isLoadedUnsafe else { return }
        switch detectionMode {
        case .off:
            break
        case .unifDetect:
            runUnifDetect(pitch: p, roll: r, yaw: y,
                          rotX: rx, rotY: ry, rotZ: rz, rotMag: rMag,
                          uaMag: uaMag,
                          userAccelX: uax, userAccelY: uay, userAccelZ: uaz,
                          gravityX: gx, gravityY: gy, gravityZ: gz,
                          sensorTime: data.timestamp)
        }

        // 100Hz DM contact check — always runs, primary contact path
        checkPendingUnifShapesWithDM(currentMotionTime: data.timestamp)

        // Expire stale pending TV shapes if raw accel data isn't flowing
        expireStaleTVShapes(motionTime: data.timestamp)
    }

    // MARK: - Unif Detect (single unified detector, tri-state classification)

    private func runUnifDetect(pitch: Double, roll: Double, yaw: Double,
                               rotX: Double, rotY: Double, rotZ: Double, rotMag: Double,
                               uaMag: Double,
                               userAccelX: Double, userAccelY: Double, userAccelZ: Double,
                               gravityX: Double, gravityY: Double, gravityZ: Double,
                               sensorTime: TimeInterval) {
        let sample = MotionSample(
            pitch: pitch, roll: roll, yaw: yaw,
            rotX: rotX, rotY: rotY, rotZ: rotZ, rotMag: rotMag,
            uaMag: uaMag,
            userAccelX: userAccelX, userAccelY: userAccelY, userAccelZ: userAccelZ,
            gravityX: gravityX, gravityY: gravityY, gravityZ: gravityZ,
            sensorTime: sensorTime
        )

        unifiedDetector.process(sample)
        if let shapeEvent = unifiedDetector.pendingShapeEvent {
            unifiedDetector.pendingShapeEvent = nil
            let rawAge = latestRawAccelTime > 0 ? (shapeEvent.fsPeakT - latestRawAccelTime) * 1000 : -1.0
            dprint("⌚ [UNIF_SHAPE type=\(shapeEvent.classification.rawValue) fsPeakT=\(f3(shapeEvent.fsPeakT)) fsPeakRotMag=\(f3(shapeEvent.fsPeakRotMag)) rawAge=\(f1(rawAge))ms]")

            if !requirePostPairingGates {
                // Gates-off auto-fire path: same buffer-clear semantics
                // as the gates-on success path (`fireUnifConfirmed`).
                clearRejectionsSinceLastStroke()
                let result = unifiedDetector.buildResult(from: shapeEvent)
                dprint("⌚ [UNIF_FIRE type=\(shapeEvent.classification.rawValue) fsPeakT=\(f3(shapeEvent.fsPeakT)) (gates off)]")
                fireSmartDetection(result: result, shapeEvent: shapeEvent)
            } else {
                eventsLock.lock()
                pendingUnifShapes.append(shapeEvent)
                eventsLock.unlock()
                dprint("⌚ [UNIF_TV_QUEUED type=\(shapeEvent.classification.rawValue) fsPeakT=\(f3(shapeEvent.fsPeakT))]")
            }
        }
    }

    private func resetAllDetectors() {
        unifiedDetector.reset()
    }

    func resetToIdle() {
        resetAllDetectors()
    }

    func fireSmartDetection(
        result: SwingDetectionResult,
        shapeEvent: UnifiedShapeEvent? = nil,
        contactTV: Double? = nil,
        contactN: Int? = nil,
        contactTVX: Double? = nil,
        contactTVY: Double? = nil,
        contactTVZ: Double? = nil,
        extremaSpread: Double? = nil,
        baselineTV: Double? = nil,
        baselineN: Int? = nil,
        /// Per-gate value/limit/margin/passed. Recorded on passes too, so a
        /// detection that only just cleared a gate says so on its own row.
        gateReport: [String: [String: Double]]? = nil
    ) {
        // Pedometer counter restarts here so the next inter-swing window
        // measures from this detection forward. Practice-shot dedup later
        // reads stepsSinceLastDetectedSwing at the moment of the next
        // detection.
        resetStepsSinceLastDetectedSwing()

        ClientEventLogger.log("swing.fire.enter", detail: [
            "hasLocation": .bool(locationManager.location != nil),
            "hasShapeEvent": .bool(shapeEvent != nil),
            "selectedClubType": selectedClubTypeName.map { .string($0) } ?? .null,
            "isPutterSelected": .bool(isPutterSelected),
            "raw800Running": .bool(isBatchedAccelRunning),
            "workoutSessionState": .string("\(WorkoutManager.shared.session?.state.rawValue ?? -1)")
        ])
        // Position is context for a stroke, not a precondition for detecting a
        // swing — but this used to bail unconditionally without one, which
        // silently discarded the detection AND its motion slice. Swing Test
        // Mode runs with no round and usually indoors, exactly where a fix is
        // least likely, so under the old guard every test detection would have
        // vanished at this line. A test detection has no stroke to place, so it
        // carries an explicitly invalid coordinate rather than a plausible-
        // looking zero.
        let coordinate: CLLocationCoordinate2D
        if let location = locationManager.location {
            coordinate = location.coordinate
        } else if testModeActive {
            coordinate = kCLLocationCoordinate2DInvalid
            ClientEventLogger.log("swing.fire.noLocation.testMode")
        } else {
            ClientEventLogger.log("swing.fire.bail.noLocation")
            dprint("⌚ [SwingDetection] Swing detected but no location available")
            return
        }

        // Ball launch bearing from the detector's swing direction. The paired
        // shape's BS-top and FS-peak times ARE the segmentation it needs.
        // Nil for a shape with no buffered window; the stroke-recording paths
        // then record a nil heading. There is deliberately no bearing-to-hole
        // fallback — it produced a number indistinguishable from a real
        // measurement while carrying none of the information.
        let swingHeading = shapeEvent.flatMap {
            unifiedDetector.swingBearing(bsTopT: $0.bsTopT, fsPeakT: $0.fsPeakT)
        }
        if let h = swingHeading {
            ClientEventLogger.log("swing.direction", detail: [
                "bearing": .double(h),
                "type": .string(result.type.rawValue)
            ])
        }

        let swing = DetectedSwing(
            location: coordinate,
            timestamp: Date(),
            peakAcceleration: result.peakAcceleration,
            trajectoryHeading: swingHeading,
            swingType: result.type,
            fsPeakRotMag: result.fsPeakRotMag,
            fsBsRatio: result.fsBsRatio,
            bsTopPitch: result.bsTopPitch,
            bsTopRoll: result.bsTopRoll,
            preStrokePitch: result.preStrokePitch,
            preStrokeRoll: result.preStrokeRoll,
            bsPeakRotX: result.bsPeakRotX,
            bsPeakRotY: result.bsPeakRotY,
            bsPeakRotZ: result.bsPeakRotZ,
            bsPeakRotMag: result.bsPeakRotMag,
            fsPeakRotX: result.fsPeakRotX,
            fsPeakRotY: result.fsPeakRotY,
            fsPeakRotZ: result.fsPeakRotZ
        )

        // Build detection metadata if shape event is available
        var detectionMeta: DetectionMetadata?
        if let shape = shapeEvent {
            let classification = shape.classification
            let metadata = DetectionMetadata(
                strokeId: nil,
                timestamp: Date(),
                swingType: result.type,
                classification: classification,
                setupStartT: shape.setupStartT,
                setupEndT: shape.setupEndT,
                setupDuration: shape.setupEndT - shape.setupStartT,
                bsTopT: shape.bsTopT,
                bsClassification: shape.bsClassification,
                bsRotMag: result.bsPeakRotMag,
                bsProminence: shape.bsProminence,
                bsPeakRotX: result.bsPeakRotX,
                bsPeakRotY: result.bsPeakRotY,
                bsPeakRotZ: result.bsPeakRotZ,
                bsTopPitch: result.bsTopPitch,
                bsTopRoll: result.bsTopRoll,
                bsAreaBeforeX: shape.bsAreaBeforeX,
                bsAreaBeforeY: shape.bsAreaBeforeY,
                bsAreaBeforeZ: shape.bsAreaBeforeZ,
                bsAreaAfterX: shape.bsAreaAfterX,
                bsAreaAfterY: shape.bsAreaAfterY,
                bsAreaAfterZ: shape.bsAreaAfterZ,
                fsPeakT: shape.fsPeakT,
                fsClassification: shape.fsClassification,
                fsPeakRotMag: result.fsPeakRotMag,
                fsProminence: shape.fsProminence,
                fsPeakRotX: result.fsPeakRotX,
                fsPeakRotY: result.fsPeakRotY,
                fsPeakRotZ: result.fsPeakRotZ,
                fsAreaBeforeX: shape.fsAreaBeforeX,
                fsAreaBeforeY: shape.fsAreaBeforeY,
                fsAreaBeforeZ: shape.fsAreaBeforeZ,
                fsAreaAfterX: shape.fsAreaAfterX,
                fsAreaAfterY: shape.fsAreaAfterY,
                fsAreaAfterZ: shape.fsAreaAfterZ,
                fsBsRatio: result.fsBsRatio,
                peakAcceleration: result.peakAcceleration,
                preStrokePitch: result.preStrokePitch,
                preStrokeRoll: result.preStrokeRoll,
                contactTV: contactTV,
                contactN: contactN,
                contactTVX: contactTVX,
                contactTVY: contactTVY,
                contactTVZ: contactTVZ,
                extremaSpread: extremaSpread,
                baselineTV: baselineTV,
                baselineN: baselineN,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                trajectoryHeading: swingHeading
            )
            detectionMeta = metadata
            DispatchQueue.main.async { self.lastDetectionMetadata = metadata }
        }

        // Cache motion slice for every detection (used by undo to send false positive CSV)
        let motionWindowEnd = shapeEvent.map { $0.fsPeakT + 1.0 } ?? (lastDeviceMotionSensorTime + 0.5)
        let motionWindowStart = shapeEvent.map { $0.bsTopT - 2.0 } ?? (motionWindowEnd - 5.0)
        rollingBufferLock.lock()
        let motionSlice = rollingMotionBuffer.filter { $0.sensorTime >= motionWindowStart && $0.sensorTime <= motionWindowEnd }
        rollingBufferLock.unlock()
        DispatchQueue.main.async { self.lastDetectionMotionSlice = motionSlice }

        // Capture 800Hz raw accel slice (if running) over the same time window
        eventBufferLock.lock()
        let rawAccelSlice = eventRawAccelBuffer.samples(in: motionWindowStart...motionWindowEnd)
        eventBufferLock.unlock()

        // Upload to Supabase (pending lifecycle — see docs/BACKEND.md)
        if let meta = detectionMeta {
            let clubType = selectedClubTypeName
            let isAutoAdd = autoAdd
            ClientEventLogger.log("swing.upload.dispatch", detail: [
                "motionSampleCount": .integer(motionSlice.count),
                "rawAccelSampleCount": .integer(rawAccelSlice.count),
                "clubType": clubType.map { .string($0) } ?? .null,
                "autoAdd": .bool(isAutoAdd)
            ])
            let eventId = SupabaseUploader.shared.onSwingDetected(
                metadata: meta,
                motionSlice: motionSlice,
                rawAccelSlice: rawAccelSlice,
                clubType: clubType,
                autoAdd: isAutoAdd,
                gateReport: gateReport
            )
            // Publish the event id so the auto-add UI flow can pair it with
            // the just-created stroke (for later false-positive marking on
            // undo). Only set in auto-add mode — manual mode returns nil.
            DispatchQueue.main.async { self.lastSwingEventId = eventId }

            // Re-upload the 800Hz slice once the batches covering this stroke
            // have actually been delivered. The synchronous slice above is
            // taken at confirm time and reliably stops before impact (see
            // uploadRawAccelLate); detection keeps its own timing, only the
            // stored copy is corrected.
            if let eventId {
                let start = motionWindowStart, end = motionWindowEnd
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + rawAccelSettleDelay) { [weak self] in
                    guard let self else { return }
                    self.eventBufferLock.lock()
                    let late = self.eventRawAccelBuffer.samples(in: start...end)
                    self.eventBufferLock.unlock()
                    guard late.count > rawAccelSlice.count else { return }
                    ClientEventLogger.log("swing.upload.rawLate.dispatch", detail: [
                        "eventId": .string(eventId.uuidString),
                        "wasCount": .integer(rawAccelSlice.count),
                        "nowCount": .integer(late.count)
                    ])
                    SupabaseUploader.shared.uploadRawAccelLate(eventId: eventId, slice: late)
                }
            }
        } else {
            ClientEventLogger.log("swing.upload.skipped.noMetadata")
        }

        // This detection accounts for the motion behind it, so a later
        // lookback capture must not reach back past here and re-upload the
        // same swing as a miss.
        markCaptureBoundary()

        DispatchQueue.main.async { self.lastDetectedSwing = swing }
        playFeedback()
    }

    // MARK: - Formatting

    func f1(_ v: Double) -> String { String(format: "%.1f", v) }
    func f2(_ v: Double) -> String { String(format: "%.2f", v) }
    func f3(_ v: Double) -> String { String(format: "%.3f", v) }

    // The following feature areas live in their own extension files:
    //  - Raw accel / 800Hz batched sensor lifecycle → SwingDetectionManager+RawAccel.swift
    //  - Post-pairing gates (contact + timing + dynamics + smoothness) + pending-shape checks → SwingDetectionManager+PostPairingGates.swift


    // MARK: - Feedback

    func startExtendedSession() {
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        extendedSession = session
        dprint("⌚ [SwingDetection] Extended runtime session started")
    }

    private func playFeedback() {
        // Three spaced double-pulses, 0.45s apart, so a detection is
        // unmistakable mid follow-through — a single buzz was too easy to miss.
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.45) {
                WKInterfaceDevice.current().play(.start)
                WKInterfaceDevice.current().play(.retry)
            }
        }
    }

    /// Whether a new auto-added swing should replace the previous auto-added
    /// stroke (= treat as practice swing). True when **both** signals say
    /// the user hasn't moved between the previous stroke and the new
    /// detection: GPS distance < ignorePracticeRadius AND step count <
    /// stepGateThreshold. Step count is read from
    /// `stepsSinceLastDetectedSwing` (live CMPedometer counter, reset on
    /// every detection).
    ///
    /// Putts are exempted (always returns false) — they're inherently
    /// short and would dedup tap-ins. Same for non-putt strokes outside
    /// the radius+step gates.
    ///
    /// Both gates configurable via UserDefaults — set the step threshold
    /// arbitrarily high to disable the step half of the AND.
    func shouldReplacePreviousStroke(newLocation: CLLocationCoordinate2D,
                                     previousLocation: CLLocationCoordinate2D,
                                     swingType: SwingType) -> Bool {
        guard ignorePractice, swingType != .putt else { return false }
        let newLoc = CLLocation(latitude: newLocation.latitude, longitude: newLocation.longitude)
        let prevLoc = CLLocation(latitude: previousLocation.latitude, longitude: previousLocation.longitude)
        let distanceYards = newLoc.distance(from: prevLoc) * 1.09361
        let stillNearby = distanceYards <= ignorePracticeRadius
        let stillFew = stepsSinceLastDetectedSwing < stepGateThreshold
        return stillNearby && stillFew
    }

    func clearLastSwing() {
        lastDetectedSwing = nil
        dprint("⌚ [SwingDetection] Cleared last detected swing")
    }

    func cacheDetectionMetadata(strokeId: UUID, metadata: DetectionMetadata) {
        var updated = metadata
        updated.strokeId = strokeId
        detectionMetadataCache[strokeId] = updated
        detectionMotionCache[strokeId] = lastDetectionMotionSlice
        // Keep cache small — only last 5
        if detectionMetadataCache.count > 5 {
            let oldest = detectionMetadataCache.min { $0.value.timestamp < $1.value.timestamp }
            if let key = oldest?.key {
                detectionMetadataCache.removeValue(forKey: key)
                detectionMotionCache.removeValue(forKey: key)
            }
        }
    }

    func logUndoEvent(strokeId: UUID) {
        // Backend (Supabase) is the source of truth for swing diagnostics
        // now — `markFalsePositive(eventId:)` flips the row's label there.
        // We just clear the local caches so they don't grow indefinitely.
        detectionMetadataCache.removeValue(forKey: strokeId)
        detectionMotionCache.removeValue(forKey: strokeId)
    }

    /// Simulate a swing for testing in simulator
    func simulateSwing() {
        guard let location = locationManager.location else {
            dprint("⌚ [SwingDetection] Cannot simulate swing - no location available")
            return
        }

        let swing = DetectedSwing(
            location: location.coordinate,
            timestamp: Date(),
            peakAcceleration: 3.5,
            trajectoryHeading: nil,
            swingType: .swing,
            fsPeakRotMag: 0, fsBsRatio: 0,
            bsTopPitch: 0, bsTopRoll: 0,
            preStrokePitch: 0, preStrokeRoll: 0,
            bsPeakRotX: 0, bsPeakRotY: 0, bsPeakRotZ: 0, bsPeakRotMag: 0,
            fsPeakRotX: 0, fsPeakRotY: 0, fsPeakRotZ: 0
        )

        DispatchQueue.main.async { self.lastDetectedSwing = swing }
        playFeedback()
        dprint("⌚ [SwingDetection] Simulated swing at \(location.coordinate)")
    }

}

// MARK: - Algorithm log values

private extension AlgorithmLog.Value {
    var anyJSON: AnyJSON {
        switch self {
        case .string(let v): return .string(v)
        case .integer(let v): return .integer(v)
        case .double(let v): return .double(v)
        case .bool(let v): return .bool(v)
        }
    }
}

// MARK: - Phone Logging

extension SwingDetectionManager {
    func phoneLog(_ message: String) {
        dprint("⌚ \(message)")
        let payload: [String: Any] = ["type": "watchLog", "msg": message]
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
    }
}

// MARK: - WKExtendedRuntimeSessionDelegate

extension SwingDetectionManager: WKExtendedRuntimeSessionDelegate {
    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        dprint("⌚ [SwingDetection] Extended runtime session active — screen-off haptics enabled")
    }

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        dprint("⌚ [SwingDetection] Extended runtime session expiring — restarting")
        startExtendedSession()
    }

    func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                error: Error?) {
        dprint("⌚ [SwingDetection] Extended runtime session invalidated: \(reason), error: \(String(describing: error))")
        extendedSession = nil
    }
}
