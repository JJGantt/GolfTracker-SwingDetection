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
            print("⌚ [WorkoutManager] HealthKit is not available on this device")
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
            print("⌚ [WorkoutManager] requestAuthorization completed: success=\(success) error=\(errMsg)")
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
            print("⌚ [WorkoutManager] Workout session started (no data collection)")
        } catch {
            print("⌚ [WorkoutManager] Failed to start workout: \(error.localizedDescription)")
        }
    }

    func endWorkout() {
        guard let session = session else {
            print("⌚ [WorkoutManager] No active workout session to end")
            return
        }
        session.end()
        print("⌚ [WorkoutManager] Workout session ended")
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
                print("⌚ [WorkoutManager] HKWorkoutSession → RUNNING (app should stay alive screen-off)")
                self.onSessionRunning?()
                self.onSessionRunning = nil
            case .ended:
                print("⌚ [WorkoutManager] HKWorkoutSession → ended")
                self.isWorkoutActive = false
            case .paused:
                print("⌚ [WorkoutManager] HKWorkoutSession → paused")
            case .prepared:
                print("⌚ [WorkoutManager] HKWorkoutSession → prepared")
            case .stopped:
                print("⌚ [WorkoutManager] HKWorkoutSession → stopped")
                self.isWorkoutActive = false
            case .notStarted:
                print("⌚ [WorkoutManager] HKWorkoutSession → notStarted")
                self.isWorkoutActive = false
                break
            @unknown default:
                print("⌚ [WorkoutManager] HKWorkoutSession → unknown state")
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession,
                       didFailWithError error: Error) {
        print("⌚ [WorkoutManager] HKWorkoutSession FAILED: \(error.localizedDescription)")
        DispatchQueue.main.async {
            self.isWorkoutActive = false
        }
    }
}

