import SwiftUI

struct ContentView: View {
    @StateObject private var store = WatchDataStore.shared
    @StateObject private var workoutManager = WorkoutManager.shared

    var body: some View {
        WatchHomeView()
            .onChange(of: store.currentRoundId) { oldId, newId in
                // If round is cleared, end the workout
                if oldId != nil && newId == nil && workoutManager.isWorkoutActive {
                    dprint("⌚ [ContentView] Round ended, stopping workout")
                    workoutManager.endWorkout()
                }
            }
    }
}

#Preview {
    ContentView()
}
