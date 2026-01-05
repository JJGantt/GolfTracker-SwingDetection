import SwiftUI

struct ContentView: View {
    @StateObject private var store = WatchDataStore.shared
    @StateObject private var connectivity = WatchConnectivityManager.shared
    @StateObject private var workoutManager = WorkoutManager.shared

    var body: some View {
        NavigationStack {
            if let round = store.currentRound, !round.holes.isEmpty {
                // Active round with holes - show the playing view
                ActiveRoundView()
            } else if store.currentRound != nil {
            // Round received but no holes - loading
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)

                Text("Loading course data...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
        } else {
            // No active round - show waiting screen with connection status
            VStack(spacing: 16) {
                Image(systemName: "figure.golf")
                    .font(.system(size: 60))
                    .foregroundColor(.green)

                Text("Golf Tracker")
                    .font(.headline)

                if connectivity.isActivated {
                    if connectivity.isReachable {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                            Text("Connected")
                                .font(.caption2)
                                .foregroundColor(.green)
                        }
                    }

                    Text("Start a round on your iPhone")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Connecting...")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
            }
        }
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
