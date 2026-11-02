import Foundation
import HealthKit
import os

/// Main-actor state: every start, end and published flag changes on main, and
/// each change is visible to the next line that reads it. HealthKit's
/// callbacks arrive elsewhere and hop to main; a callback from a session that
/// has since been replaced is ignored, so ending one session and starting the
/// next never lets the old one's late `.ended` mark the new one inactive.
@MainActor
final class WorkoutManager: NSObject, ObservableObject {
    static let shared = WorkoutManager()

    let healthStore = HKHealthStore()
    private(set) var session: HKWorkoutSession? {
        didSet { Self.sessionStateMirror.withLock { [session] in $0 = session?.state ?? .notStarted } }
    }

    /// The current session's state, readable from any thread. The motion and
    /// raw-accel queues ask whether the 800Hz stream can run, and the session
    /// reference itself belongs to main.
    private nonisolated static let sessionStateMirror = OSAllocatedUnfairLock<HKWorkoutSessionState>(initialState: .notStarted)
    nonisolated static var currentSessionState: HKWorkoutSessionState { sessionStateMirror.withLock { $0 } }

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
        healthKitAuthorizationStatus = healthStore.authorizationStatus(for: workoutType)
    }

    // MARK: - Authorization

    func requestAuthorization(completion: @escaping @MainActor (Bool, Error?) -> Void) {
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

        healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead) { success, error in
            let errMsg = error?.localizedDescription ?? "none"
            dprint("⌚ [WorkoutManager] requestAuthorization completed: success=\(success) error=\(errMsg)")
            // HealthKit calls back on a background queue, and every caller's
            // next step is `startWorkout()`, which publishes `isWorkoutActive`.
            // Run from there, that SwiftUI update happened off the main thread
            // and UIKit aborted the app ("These UI changes are not supported
            // off the main thread") — on the watch 2026-05-08 (twice) and at
            // round start 2026-09-13. Hand the result over on main.
            Task { @MainActor in
                WorkoutManager.shared.refreshAuthorizationStatus()
                completion(success, error)
            }
        }
    }

    // MARK: - Workout Session

    /// Recompute `keepAliveActive` from the current session + collection state.
    private func refreshKeepAlive() {
        keepAliveActive = sessionState == .running && (!collectingRequested || isCollecting)
    }

    /// Publishes `isWorkoutActive` synchronously so the next caller sees it.
    /// A no-op while a session is already active — round
    /// start asks twice (`SwingDetectionManager.startMonitoring` and
    /// `ActiveRoundView.handleViewAppear` each request authorization and start
    /// a workout in the callback), and the second call used to replace `session`
    /// with a new one, leaving the first running with nothing referencing it.
    func startWorkout() {
        guard !isWorkoutActive else {
            dprint("⌚ [WorkoutManager] startWorkout: session already active — ignoring")
            return
        }
        let collecting = useCollectingBuilder
        collectingRequested = collecting
        isCollecting = false
        lastFailure = nil
        refreshKeepAlive()

        // Golf rounds: builderless outdoor session (kept alive by the round's
        // continuous GPS, optical HR never spins up). Sensor capture: an actively
        // collecting indoor session, which is what keeps sensors alive screen-off
        // without GPS.
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = collecting ? .other : .golf
        configuration.locationType = collecting ? .indoor : .outdoor

        do {
            let newSession = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            newSession.delegate = self
            session = newSession

            if collecting {
                // beginCollection makes this a genuinely-running workout so CoreMotion
                // and the 800Hz batched stream keep delivering wrist-down. The workout
                // is discarded on end (endWorkout) so nothing lands in Health.
                let builder = newSession.associatedWorkoutBuilder()
                builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore,
                                                             workoutConfiguration: configuration)
                liveBuilder = builder
                newSession.startActivity(with: Date())
                builder.beginCollection(withStart: Date()) { ok, err in
                    dprint("⌚ [WorkoutManager] capture beginCollection ok=\(ok) err=\(err?.localizedDescription ?? "none")")
                    let message = err?.localizedDescription ?? "unknown"
                    Task { @MainActor in
                        let manager = WorkoutManager.shared
                        guard manager.session === newSession else { return }
                        manager.isCollecting = ok
                        if !ok { manager.lastFailure = "beginCollection: \(message)" }
                        manager.refreshKeepAlive()
                    }
                }
                isWorkoutActive = true
                dprint("⌚ [WorkoutManager] Collecting workout started (sensor capture, screen-off safe)")
            } else {
                // Session alone keeps a round's app alive screen-off; no builder so the
                // optical heart rate sensor is never activated.
                newSession.startActivity(with: Date())
                isWorkoutActive = true
                dprint("⌚ [WorkoutManager] Workout session started (no data collection)")
            }
        } catch {
            dprint("⌚ [WorkoutManager] Failed to start workout: \(error.localizedDescription)")
            lastFailure = "session init: \(error.localizedDescription)"
            refreshKeepAlive()
        }
    }

    /// Ends the session and clears every flag before returning, so a
    /// `startWorkout()` on the very next line starts a new one. These used to
    /// clear on a later main-queue hop, and a start in between saw
    /// `isWorkoutActive` still true and was ignored — then the hop cleared the
    /// flags (and `session`) out from under the session that should have
    /// started.
    func endWorkout() {
        guard let session = session else {
            dprint("⌚ [WorkoutManager] No active workout session to end")
            return
        }
        // Tear down + discard the capture builder (if any) so no stray workout is
        // saved to Health, then end the session.
        if let builder = liveBuilder {
            liveBuilder = nil
            builder.endCollection(withEnd: Date()) { _, _ in
                builder.discardWorkout()
            }
        }
        session.end()
        useCollectingBuilder = false
        collectingRequested = false
        dprint("⌚ [WorkoutManager] Workout session ended")
        isWorkoutActive = false
        isCollecting = false
        self.session = nil
        sessionState = .ended
        refreshKeepAlive()
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                       didChangeTo toState: HKWorkoutSessionState,
                       from fromState: HKWorkoutSessionState,
                       date: Date) {
        let changed = ObjectIdentifier(workoutSession)
        Task { @MainActor in
            // A session already ended and replaced still reports its own
            // transitions; they describe nothing current.
            guard let current = self.session, ObjectIdentifier(current) == changed else { return }
            Self.sessionStateMirror.withLock { $0 = toState }
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

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                       didFailWithError error: Error) {
        dprint("⌚ [WorkoutManager] HKWorkoutSession FAILED: \(error.localizedDescription)")
        let failed = ObjectIdentifier(workoutSession)
        let message = error.localizedDescription
        Task { @MainActor in
            guard let current = self.session, ObjectIdentifier(current) == failed else { return }
            self.isWorkoutActive = false
            self.lastFailure = "session failed: \(message)"
            self.refreshKeepAlive()
        }
    }
}

