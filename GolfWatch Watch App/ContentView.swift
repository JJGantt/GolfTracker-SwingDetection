import SwiftUI

struct ContentView: View {
    @StateObject private var store = WatchDataStore.shared
    @StateObject private var workoutManager = WorkoutManager.shared

    var body: some View {
        WatchHomeView()
            .onChange(of: store.currentRound) { oldRound, newRound in
                // If round is cleared, end the workout
                if oldRound != nil && newRound == nil && workoutManager.isWorkoutActive {
                    print("⌚ [ContentView] Round ended, stopping workout")
                    workoutManager.endWorkout()
                }
            }
    }
}

#Preview {
    ContentView()
}
