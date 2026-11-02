import Foundation
import os
@preconcurrency import CoreMotion
import WatchKit
import StrokeSaverAlgorithms

// Starting and stopping motion monitoring: authorization, the workout
// session, and the device-motion stream.
extension SwingDetectionManager {

    func setupMotionManager() {
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

    /// The wrist and crown side from the watch's orientation setting. The
    /// detector normalises motion to the wear its thresholds were measured on
    /// (`WearFrame`), so this has to be what the user actually wears.
    @MainActor
    static var currentWear: WearFrame {
        let device = WKInterfaceDevice.current()
        return WearFrame(wrist: device.wristLocation == .right ? .right : .left,
                         crown: device.crownOrientation == .left ? .left : .right)
    }

    @MainActor
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
        let wear = Self.currentWear
        withDetector { $0.wear = wear }
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
                    WorkoutManager.shared.lastFailure =
                        "HealthKit workout access denied\(error.map { ": \($0.localizedDescription)" } ?? "")"
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
        startDeviceMotionUpdates()
    }

    /// Not main-actor on purpose. A closure written inside a main-actor
    /// method is itself main-actor, and CoreMotion's handler type is not
    /// `@Sendable`, so the compiler would let it through and the runtime would
    /// trap on the first sample delivered to `motionQueue`.
    private nonisolated func startDeviceMotionUpdates() {
        motionManager.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: motionQueue) { [weak self] data, error in
            guard let self = self, let data = data else { return }
            self.processDeviceMotion(data)
        }
    }

    @MainActor
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
        resetToIdle()
    }
}
