import Foundation
import os
@preconcurrency import CoreMotion
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

/// Shared across main, `motionQueue` and `rawAccelQueue`; see "Threads" in
/// CLAUDE.md for which lock covers which state. Its `@Published` properties
/// are written on main only.
final class SwingDetectionManager: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = SwingDetectionManager()

    let motionManager = CMMotionManager()
    let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        return q
    }()
    var extendedSession: WKExtendedRuntimeSession?

    @Published var lastDetectedSwing: DetectedSwing?
    /// For the UI. Code off the main thread reads `monitoringActive`: the
    /// motion and raw-accel queues test it on every sample, and a `@Published`
    /// property read there while main writes it is a data race.
    @Published var isMonitoring: Bool = false {
        didSet { monitoringFlag.withLock { $0 = isMonitoring } }
    }
    private let monitoringFlag = OSAllocatedUnfairLock(initialState: false)
    var monitoringActive: Bool { monitoringFlag.withLock { $0 } }

    /// What the motion and raw-accel queues need to know about settings main
    /// owns, plus the 800Hz stream flags those queues read and write. Every
    /// `@Published` setting the queues consult mirrors itself in here from
    /// its `didSet`, the same way `isMonitoring` does into `monitoringFlag`;
    /// off-main code reads `engine`, never the published property.
    struct EngineState: Sendable {
        var detectionMode: DetectionMode = .unifDetect
        var requirePostPairingGates = true
        var autoAdd = true
        var selectedClubTypeName: String?
        var testModeActive = false
        var rawAccelRunningForCapture = false
        var isBatchedAccelRunning = false
        var isUsingFallbackRawAccel = false
        var rawAccelMissingWarned = false
    }
    let engineState = OSAllocatedUnfairLock(initialState: EngineState())
    var engine: EngineState { engineState.withLock { $0 } }

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
            engineState.withLock { [detectionMode] in $0.detectionMode = detectionMode }
            updateRawAccelForCapture()
        }
    }

    // MARK: - Unif Detect (single detector, tri-state classification)

    /// The detector is fed on `motionQueue`, asked for a launch bearing from
    /// whichever queue confirms a shape (the 800Hz override confirms on
    /// `rawAccelQueue`), and reset from main. It is not thread-safe itself, so
    /// every use goes through `withDetector`, which holds `detectorLock`.
    /// Never call `withDetector` from inside another `withDetector`, and never
    /// fire a detection while holding it: `fireSmartDetection` takes it again
    /// for the bearing.
    let unifiedDetector: UnifiedDetector
    private let detectorLock = NSLock()

    func withDetector<R>(_ body: (UnifiedDetector) -> R) -> R {
        detectorLock.lock()
        defer { detectorLock.unlock() }
        return body(unifiedDetector)
    }

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
            engineState.withLock { [requirePostPairingGates] in $0.requirePostPairingGates = requirePostPairingGates }
        }
    }

    // Auto-add: detected swings are automatically added as strokes
    @Published var autoAdd: Bool = true {
        didSet {
            UserDefaults.standard.set(autoAdd, forKey: "autoAdd")
            engineState.withLock { [autoAdd] in $0.autoAdd = autoAdd }
        }
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
    @Published var selectedClubTypeName: String? = nil {
        didSet { engineState.withLock { [selectedClubTypeName] in $0.selectedClubTypeName = selectedClubTypeName } }
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

    /// Stream liveness. Written by the batch-delivery task and by the 1Hz
    /// check on `motionQueue`, so it lives behind its own lock; the published
    /// properties above are main's copy for the UI and are never read here.
    struct Raw800Liveness {
        var lastBatchWall: Date?
        var lastCheckSensorTime: TimeInterval = 0
        var state: Raw800State = .off
        var downSince: Date?
        var downLogged = false
        /// Watchdog restarts since the last delivered batch, and the earliest
        /// the next one may run. Backoff doubles from 2s to a 60s ceiling so a
        /// sensor that will not come back costs one restart a minute, not a
        /// busy loop.
        var restartAttempts = 0
        var nextRestartAt: Date?
    }
    let raw800Liveness = OSAllocatedUnfairLock(initialState: Raw800Liveness())

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
    /// Appended on `motionQueue` and `rawAccelQueue` (each gate stage
    /// rejects on its own queue), claimed and counted on main. Only touched
    /// with `rejectionsLock` held.
    var rejectedShapesSinceLastStroke: [RejectedShape] = []
    let rejectionsLock = NSLock()

    // MARK: - Lookback Capture

    /// True while Swing Test Mode owns the detector. Read by
    /// `fireSmartDetection` so a detection is not discarded for want of a GPS
    /// fix, which test mode frequently has none of.
    @Published var testModeActive: Bool = false {
        didSet { engineState.withLock { [testModeActive] in $0.testModeActive = testModeActive } }
    }

    /// Sensor time up to which motion is already accounted for — by a fired
    /// detection or by an earlier lookback capture. A capture never reaches
    /// back past this, so pressing the button twice cannot upload the same
    /// swing twice, and a capture following a real detection contains only the
    /// motion since that detection.
    ///
    /// Held with the latest sample time in one lock: the motion queue writes
    /// both, a lookback on main reads and moves both.
    struct SensorClock {
        var latestSample: TimeInterval = 0
        var captureBoundary: TimeInterval = 0
    }
    let sensorClock = OSAllocatedUnfairLock(initialState: SensorClock())

    /// Sensor time of the latest device-motion sample.
    var lastDeviceMotionSensorTime: TimeInterval { sensorClock.withLock { $0.latestSample } }

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

    // Shapes that failed the 100Hz DM check but may be overridden by 800Hz raw accel (putter mode)
    var pendingUnifShapesDMFailed: [UnifiedShapeEvent] = []
    let eventsLock = NSLock()

    // Staleness tracking for expireStaleTVShapes (defined in +PostPairingGates)
    var lastStaleCheckTime: TimeInterval = 0
    var rawAccelMissingWarned: Bool {
        get { engineState.withLock { $0.rawAccelMissingWarned } }
        set { engineState.withLock { $0.rawAccelMissingWarned = newValue } }
    }

    /// Most recent raw accel sample timestamp. Written on rawAccelQueue, read
    /// on motionQueue, so it is behind a lock: an unsynchronised Double shared
    /// across threads is a data race whatever the hardware does with it.
    let latestRawAccelTime = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)

    var detectionMetadataCache: [UUID: DetectionMetadata] = [:]
    var detectionMotionCache: [UUID: [RecordedDataPoint]] = [:]
    var lastDetectionMetadata: DetectionMetadata?
    var lastDetectionMotionSlice: [RecordedDataPoint] = []
    /// The swing_events row id of the most recent auto-add upload. Set by
    /// `fireSmartDetection` after the synchronous-returned id from
    /// `SupabaseUploader.onSwingDetected`. The auto-add UI flow reads this
    /// to pair the stroke with its event (for false-positive marking on
    /// undo). Nil when the most recent detection was manual (no immediate
    /// upload — pending lifecycle handles labeling there).
    var lastSwingEventId: UUID?

    let rawAccelQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        return q
    }()

    // CMBatchedSensorManager — 800 Hz raw accelerometer
    let batchedSensorManager = CMBatchedSensorManager()
    var batchedAccelTask: Task<Void, Never>?
    var isBatchedAccelRunning: Bool {
        get { engineState.withLock { $0.isBatchedAccelRunning } }
        set { engineState.withLock { $0.isBatchedAccelRunning = newValue } }
    }
    var isUsingFallbackRawAccel: Bool {
        get { engineState.withLock { $0.isUsingFallbackRawAccel } }
        set { engineState.withLock { $0.isUsingFallbackRawAccel = newValue } }
    }
    /// Serializes every 800Hz start and stop — see `startRawAccelLocked`.
    let rawAccelControlLock = NSLock()

    // Core Motion authorization
    @Published var motionAuthStatus: CMAuthorizationStatus = .notDetermined
    @Published var rawAccelAuthOK: Bool = true
    let activityManager = CMMotionActivityManager()

    // Pedometer — counts steps since the last detected swing. Published
    // so the watch can render a small live debug readout. Reset to 0
    // every time `fireSmartDetection` runs (a real detection fires).
    let pedometer = CMPedometer()
    @Published var stepsSinceLastDetectedSwing: Int = 0
    var pedometerStartDate: Date = Date()
    var pedometerStartedMonitoring = false

    // HKWorkoutSession ownership
    var monitoringStartedWorkout = false

    // Swing detection parameters
    let updateInterval: TimeInterval = 0.01 // 100 Hz device motion

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
    var rawAccelRunningForCapture: Bool {
        get { engineState.withLock { $0.rawAccelRunningForCapture } }
        set { engineState.withLock { $0.rawAccelRunningForCapture = newValue } }
    }
    let eventBufferLock = NSLock()

    // Rolling buffer — 3 min at 100Hz = 18,000 samples (~660KB). Guarded by
    // `rollingBufferLock`: written on the motion queue, read from upload paths.
    static let rollingBufferDuration: TimeInterval = 180.0
    var rollingMotionBuffer = TimeWindowBuffer<RecordedDataPoint>(duration: rollingBufferDuration) { $0.sensorTime }
    let rollingBufferLock = NSLock()

    private override init() {
        // The detector reports its diagnostic-tier events through this sink;
        // they land in `client_events` behind the diagnostics toggle.
        AlgorithmLog.diagnosticSink = { event, detail in
            ClientEventLogger.log(event, level: .diagnostic, detail: detail?.mapValues { $0.anyJSON })
        }
        let detector = UnifiedDetector()
        detector.log = { msg in dprint("⌚ \(msg)") }
        unifiedDetector = detector
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
        // Observers do not run for assignments made in the initializer, so
        // copy what was loaded into the mirror explicitly.
        engineState.withLock { [detectionMode, requirePostPairingGates, autoAdd] in
            $0.detectionMode = detectionMode
            $0.requirePostPairingGates = requirePostPairingGates
            $0.autoAdd = autoAdd
        }
        setupMotionManager()
        checkAndRequestMotionAuthorization()
    }

    func processDeviceMotion(_ data: CMDeviceMotion) {
        sensorClock.withLock { $0.latestSample = data.timestamp }

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
        if monitoringActive {
            let dp = RecordedDataPoint(
                sensorTime: data.timestamp, userAccelX: uax, userAccelY: uay, userAccelZ: uaz, userAccelMag: uaMag,
                rotationX: rx, rotationY: ry, rotationZ: rz, rotationMag: rMag,
                gravityX: gx, gravityY: gy, gravityZ: gz, pitch: p, roll: r, yaw: y,
                magAccuracy: Int(magAcc)
            )
            rollingBufferLock.lock()
            rollingMotionBuffer.append(dp)
            rollingBufferLock.unlock()
        }

        checkRaw800Liveness(sensorTime: data.timestamp)

        // Detection logic. Gated on a complete config being in force (see
        // DetectorConfig); there are no compiled thresholds.
        guard DetectorParameters.isLoaded else { return }
        switch engine.detectionMode {
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

        // Feed and collect in one hold, then let go before anything fires.
        let pendingShape: UnifiedShapeEvent? = withDetector { detector in
            _ = detector.process(sample)
            defer { detector.pendingShapeEvent = nil }
            return detector.pendingShapeEvent
        }
        if let shapeEvent = pendingShape {
            let lastRaw = latestRawAccelTime.withLock { $0 }
            let rawAge = lastRaw > 0 ? (shapeEvent.fsPeakT - lastRaw) * 1000 : -1.0
            dprint("⌚ [UNIF_SHAPE type=\(shapeEvent.classification.rawValue) fsPeakT=\(f3(shapeEvent.fsPeakT)) fsPeakRotMag=\(f3(shapeEvent.fsPeakRotMag)) rawAge=\(f1(rawAge))ms]")

            if !engine.requirePostPairingGates {
                // Gates-off auto-fire path: same buffer-clear semantics
                // as the gates-on success path (`fireUnifConfirmed`).
                clearRejectionsSinceLastStroke()
                let result = withDetector { $0.buildResult(from: shapeEvent) }
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

    /// Clears the detector and the shapes waiting on their gates. Runs on
    /// `motionQueue`, behind every sample CoreMotion has already queued there,
    /// so a stop's reset is not undone by samples still in flight and a reset
    /// never lands in the middle of `processDeviceMotion`. A sample from a
    /// monitoring session started afterwards queues behind it.
    func resetToIdle() {
        motionQueue.addOperation { [weak self] in
            guard let self else { return }
            self.withDetector { $0.reset() }
            self.eventsLock.lock()
            self.pendingUnifShapes.removeAll()
            self.pendingUnifShapesDMFailed.removeAll()
            self.eventsLock.unlock()
        }
    }

    // MARK: - Extended runtime session

    func startExtendedSession() {
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        extendedSession = session
        dprint("⌚ [SwingDetection] Extended runtime session started")
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
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(WatchMessage.watchLog(message).dictionary, replyHandler: nil, errorHandler: nil)
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
