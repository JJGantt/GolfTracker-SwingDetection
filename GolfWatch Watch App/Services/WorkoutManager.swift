import Foundation
import HealthKit

class WorkoutManager: NSObject, ObservableObject {
    static let shared = WorkoutManager()

    let healthStore = HKHealthStore()
    var session: HKWorkoutSession?

    @Published var isWorkoutActive = false

    /// Called once when the HKWorkoutSession first reaches `.running`. Cleared after firing.
    var onSessionRunning: (() -> Void)?

    private override init() {
        super.init()
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

        healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead) { success, error in
            let errMsg = error?.localizedDescription ?? "none"
            dprint("⌚ [WorkoutManager] requestAuthorization completed: success=\(success) error=\(errMsg)")
            completion(success, error)
        }
    }

    // MARK: - Workout Session

    func startWorkout() {
        // Create workout configuration
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .golf
        configuration.locationType = .outdoor

        do {
            // Create workout session — the session alone keeps the app alive screen-off.
            // No builder/data source so the optical heart rate sensor is never activated.
            session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            session?.delegate = self
            session?.startActivity(with: Date())
            isWorkoutActive = true
            dprint("⌚ [WorkoutManager] Workout session started (no data collection)")
        } catch {
            dprint("⌚ [WorkoutManager] Failed to start workout: \(error.localizedDescription)")
        }
    }

    func endWorkout() {
        guard let session = session else {
            dprint("⌚ [WorkoutManager] No active workout session to end")
            return
        }
        session.end()
        dprint("⌚ [WorkoutManager] Workout session ended")
        DispatchQueue.main.async {
            self.isWorkoutActive = false
            self.session = nil
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
        }
    }
}

