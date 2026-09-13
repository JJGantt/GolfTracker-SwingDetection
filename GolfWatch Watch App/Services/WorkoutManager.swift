import Foundation
import HealthKit

class WorkoutManager: NSObject, ObservableObject {
    static let shared = WorkoutManager()

    let healthStore = HKHealthStore()
    var session: HKWorkoutSession?

    /// When set before `startWorkout()`, the session attaches an
    /// `HKLiveWorkoutBuilder` and calls `beginCollection` so it becomes an
    /// *actively collecting* workout — the only state that reliably keeps the app
    /// alive (CoreMotion + 800Hz batched accel streaming) with the screen off and
    /// wrist down. Golf rounds leave this false: their builderless session leans on
    /// the round's continuous background GPS to stay alive and avoids spinning up
    /// the optical HR sensor. Standalone sensor capture has no GPS, so it opts in.
    /// One-shot: consumed by `startWorkout()`, cleared by `endWorkout()`.
    var useCollectingBuilder = false
    private var liveBuilder: HKLiveWorkoutBuilder?

    @Published var isWorkoutActive = false
    @Published var healthKitAuthorizationStatus: HKAuthorizationStatus = .notDetermined

    /// Live session state, mirrored from the delegate. `isWorkoutActive` only says
    /// "we asked for a session"; this says whether watchOS actually granted one.
    @Published var sessionState: HKWorkoutSessionState = .notStarted
    /// True once `beginCollection` has succeeded on a capture session.
    @Published var isCollecting = false
    /// Last authorization / session / collection failure, for display.
    @Published var lastFailure: String?

    /// Whether the app is genuinely protected from suspension right now.
    ///
    /// A session that was requested but never reached `.running`, or a capture
    /// session whose `beginCollection` failed, does NOT keep CoreMotion alive
    /// once the screen sleeps — sensors stop dead and the recording is silently
    /// full of holes. Everything that depends on screen-off streaming must gate
    /// on this rather than on `isWorkoutActive`.
    @Published var keepAliveActive = false

    /// Set while a collecting (sensor-capture) session is the active one, so
    /// `keepAliveActive` knows whether `beginCollection` is required.
    private var collectingRequested = false

    private let workoutType: HKSampleType = HKQuantityType.workoutType()

    /// Called once when the HKWorkoutSession first reaches `.running`. Cleared after firing.
    var onSessionRunning: (() -> Void)?

    private override init() {
        super.init()
        refreshAuthorizationStatus()
    }

    func refreshAuthorizationStatus() {
        let status = healthStore.authorizationStatus(for: workoutType)
        DispatchQueue.main.async {
            self.healthKitAuthorizationStatus = status
        }
    }

    // MARK: - Authorization

    func requestAuthorization(completion: @escaping (Bool, Error?) -> Void) {
        // Check if HealthKit is available on this device
        guard HKHealthStore.isHealthDataAvailable() else {
            dprint("⌚ [WorkoutManager] HealthKit is not available on this device")
            completion(false, nil)
            return
        }

        // Define the types we want to read and write
        let typesToShare: Set = [
            HKQuantityType.workoutType()
        ]

        let typesToRead: Set<HKObjectType> = []

        healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead) { [weak self] success, error in
            let errMsg = error?.localizedDescription ?? "none"
            dprint("⌚ [WorkoutManager] requestAuthorization completed: success=\(success) error=\(errMsg)")
            self?.refreshAuthorizationStatus()
            // HealthKit calls back on a background queue, and every caller's
            // next step is `startWorkout()`, which publishes `isWorkoutActive`.
            // Run from here, that SwiftUI update happened off the main thread
            // and UIKit aborted the app ("These UI changes are not supported
            // off the main thread") — on the watch 2026-05-08 (twice) and at
            // round start 2026-09-13. Hand the result over on main.
            DispatchQueue.main.async { completion(success, error) }
        }
    }

    // MARK: - Workout Session

    /// Recompute `keepAliveActive` from the current session + collection state.
    /// Must be called on the main queue.
    private func refreshKeepAlive() {
        keepAliveActive = sessionState == .running && (!collectingRequested || isCollecting)
    }

    /// Main thread only: it publishes `isWorkoutActive` synchronously so the
    /// next caller sees it. A no-op while a session is already active — round
    /// start asks twice (`SwingDetectionManager.startMonitoring` and
    /// `ActiveRoundView.handleViewAppear` each request authorization and start
    /// a workout in the callback), and the second call used to replace `session`
    /// with a new one, leaving the first running with nothing referencing it.
    func startWorkout() {
        assert(Thread.isMainThread, "startWorkout publishes UI state; call it on main")
        guard !isWorkoutActive else {
            dprint("⌚ [WorkoutManager] startWorkout: session already active — ignoring")
            return
        }
        let collecting = useCollectingBuilder
        collectingRequested = collecting
        DispatchQueue.main.async {
            self.isCollecting = false
            self.lastFailure = nil
            self.refreshKeepAlive()
        }

        // Golf rounds: builderless outdoor session (kept alive by the round's
        // continuous GPS, optical HR never spins up). Sensor capture: an actively
        // collecting indoor session, which is what keeps sensors alive screen-off
        // without GPS.
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = collecting ? .other : .golf
        configuration.locationType = collecting ? .indoor : .outdoor

        do {
            session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            session?.delegate = self

            if collecting {
                // beginCollection makes this a genuinely-running workout so CoreMotion
                // and the 800Hz batched stream keep delivering wrist-down. The workout
                // is discarded on end (endWorkout) so nothing lands in Health.
                let builder = session?.associatedWorkoutBuilder()
                builder?.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore,
                                                              workoutConfiguration: configuration)
                liveBuilder = builder
                session?.startActivity(with: Date())
                builder?.beginCollection(withStart: Date()) { [weak self] ok, err in
                    dprint("⌚ [WorkoutManager] capture beginCollection ok=\(ok) err=\(err?.localizedDescription ?? "none")")
                    DispatchQueue.main.async {
                        self?.isCollecting = ok
                        if !ok {
                            self?.lastFailure = "beginCollection: \(err?.localizedDescription ?? "unknown")"
                        }
                        self?.refreshKeepAlive()
                    }
                }
                isWorkoutActive = true
                dprint("⌚ [WorkoutManager] Collecting workout started (sensor capture, screen-off safe)")
            } else {
                // Session alone keeps a round's app alive screen-off; no builder so the
                // optical heart rate sensor is never activated.
                session?.startActivity(with: Date())
                isWorkoutActive = true
                dprint("⌚ [WorkoutManager] Workout session started (no data collection)")
            }
        } catch {
            dprint("⌚ [WorkoutManager] Failed to start workout: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.lastFailure = "session init: \(error.localizedDescription)"
                self.refreshKeepAlive()
            }
        }
    }

    func endWorkout() {
        guard let session = session else {
            dprint("⌚ [WorkoutManager] No active workout session to end")
            return
        }
        // Tear down + discard the capture builder (if any) so no stray workout is
        // saved to Health, then end the session.
        if let builder = liveBuilder {
            builder.endCollection(withEnd: Date()) { [weak self] _, _ in
                builder.discardWorkout()
                self?.liveBuilder = nil
            }
        }
        session.end()
        useCollectingBuilder = false
        collectingRequested = false
        dprint("⌚ [WorkoutManager] Workout session ended")
        DispatchQueue.main.async {
            self.isWorkoutActive = false
            self.isCollecting = false
            self.session = nil
            self.refreshKeepAlive()
        }
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WorkoutManager: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession,
                       didChangeTo toState: HKWorkoutSessionState,
                       from fromState: HKWorkoutSessionState,
                       date: Date) {
        DispatchQueue.main.async {
            self.sessionState = toState
            self.refreshKeepAlive()
            switch toState {
            case .running:
                dprint("⌚ [WorkoutManager] HKWorkoutSession → RUNNING (app should stay alive screen-off)")
                self.onSessionRunning?()
                self.onSessionRunning = nil
            case .ended:
                dprint("⌚ [WorkoutManager] HKWorkoutSession → ended")
                self.isWorkoutActive = false
            case .paused:
                dprint("⌚ [WorkoutManager] HKWorkoutSession → paused")
            case .prepared:
                dprint("⌚ [WorkoutManager] HKWorkoutSession → prepared")
            case .stopped:
                dprint("⌚ [WorkoutManager] HKWorkoutSession → stopped")
                self.isWorkoutActive = false
            case .notStarted:
                dprint("⌚ [WorkoutManager] HKWorkoutSession → notStarted")
                self.isWorkoutActive = false
                break
            @unknown default:
                dprint("⌚ [WorkoutManager] HKWorkoutSession → unknown state")
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession,
                       didFailWithError error: Error) {
        dprint("⌚ [WorkoutManager] HKWorkoutSession FAILED: \(error.localizedDescription)")
        DispatchQueue.main.async {
            self.isWorkoutActive = false
            self.lastFailure = "session failed: \(error.localizedDescription)"
            self.refreshKeepAlive()
        }
    }
}

