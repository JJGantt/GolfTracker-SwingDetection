import Foundation
import HealthKit
import Combine

class WorkoutManager: NSObject, ObservableObject {
    static let shared = WorkoutManager()

    let healthStore = HKHealthStore()
    var session: HKWorkoutSession?
    var builder: HKLiveWorkoutBuilder?

    @Published var isWorkoutActive = false
    @Published var activeEnergy: Double = 0
    @Published var heartRate: Double = 0
    @Published var distance: Double = 0

    private override init() {
        super.init()
    }

    // MARK: - Authorization

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        // Check if HealthKit is available on this device
        guard HKHealthStore.isHealthDataAvailable() else {
            print("⌚ [WorkoutManager] HealthKit is not available on this device")
            completion(false)
            return
        }

        // Define the types we want to read and write
        let typesToShare: Set = [
            HKQuantityType.workoutType()
        ]

        let typesToRead: Set = [
            HKQuantityType.quantityType(forIdentifier: .heartRate)!,
            HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)!,
            HKObjectType.activitySummaryType()
        ]

        healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead) { success, error in
            if let error = error {
                print("⌚ [WorkoutManager] Authorization error: \(error.localizedDescription)")
            }
            completion(success)
        }
    }

    // MARK: - Workout Session

    func startWorkout() {
        // Create workout configuration
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .golf
        configuration.locationType = .outdoor

        do {
            // Create workout session
            session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            builder = session?.associatedWorkoutBuilder()

            // Set ourselves as delegate
            session?.delegate = self
            builder?.delegate = self

            // Set data source
            builder?.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: configuration
            )

            // Start the session
            let startDate = Date()
            session?.startActivity(with: startDate)
            builder?.beginCollection(withStart: startDate) { success, error in
                if let error = error {
                    print("⌚ [WorkoutManager] Failed to begin collection: \(error.localizedDescription)")
                } else {
                    print("⌚ [WorkoutManager] Workout started successfully")
                }
            }

            isWorkoutActive = true

        } catch {
            print("⌚ [WorkoutManager] Failed to start workout: \(error.localizedDescription)")
        }
    }

    func endWorkout() {
        guard let session = session, let builder = builder else {
            print("⌚ [WorkoutManager] No active workout session to end")
            return
        }

        // End the session
        session.end()

        // End data collection
        builder.endCollection(withEnd: Date()) { success, error in
            if let error = error {
                print("⌚ [WorkoutManager] Failed to end collection: \(error.localizedDescription)")
            }

            // Finish the workout
            builder.finishWorkout { workout, error in
                if let error = error {
                    print("⌚ [WorkoutManager] Failed to finish workout: \(error.localizedDescription)")
                } else if let workout = workout {
                    print("⌚ [WorkoutManager] Workout saved successfully: \(workout)")
                }

                DispatchQueue.main.async {
                    self.isWorkoutActive = false
                    self.session = nil
                    self.builder = nil
                }
            }
        }
    }

    func pauseWorkout() {
        session?.pause()
    }

    func resumeWorkout() {
        session?.resume()
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
                print("⌚ [WorkoutManager] Workout session running")
            case .ended:
                print("⌚ [WorkoutManager] Workout session ended")
                self.isWorkoutActive = false
            case .paused:
                print("⌚ [WorkoutManager] Workout session paused")
            case .prepared:
                print("⌚ [WorkoutManager] Workout session prepared")
            case .stopped:
                print("⌚ [WorkoutManager] Workout session stopped")
                self.isWorkoutActive = false
            case .notStarted:
                print("⌚ [WorkoutManager] Workout session not started")
                self.isWorkoutActive = false
                break
            @unknown default:
                print("⌚ [WorkoutManager] Unknown workout session state")
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession,
                       didFailWithError error: Error) {
        print("⌚ [WorkoutManager] Workout session failed: \(error.localizedDescription)")
        DispatchQueue.main.async {
            self.isWorkoutActive = false
        }
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                       didCollectDataOf collectedTypes: Set<HKSampleType>) {
        // Update published values when new data is collected
        for type in collectedTypes {
            guard let quantityType = type as? HKQuantityType else { continue }

            let statistics = workoutBuilder.statistics(for: quantityType)

            DispatchQueue.main.async {
                switch quantityType {
                case HKQuantityType.quantityType(forIdentifier: .heartRate):
                    let heartRateUnit = HKUnit.count().unitDivided(by: HKUnit.minute())
                    self.heartRate = statistics?.mostRecentQuantity()?.doubleValue(for: heartRateUnit) ?? 0

                case HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned):
                    let energyUnit = HKUnit.kilocalorie()
                    self.activeEnergy = statistics?.sumQuantity()?.doubleValue(for: energyUnit) ?? 0

                case HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning):
                    let meterUnit = HKUnit.meter()
                    self.distance = statistics?.sumQuantity()?.doubleValue(for: meterUnit) ?? 0

                default:
                    break
                }
            }
        }
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        // Handle workout events if needed
    }
}
