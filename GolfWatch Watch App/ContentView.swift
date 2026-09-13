import SwiftUI

struct ContentView: View {
    @StateObject private var store = WatchDataStore.shared
    @StateObject private var workoutManager = WorkoutManager.shared

    var body: some View {
        ZStack {
            WatchHomeView()
            // Above the whole navigation stack, so it covers the round and its
            // placement map until it is dismissed or the blobs land.
            if let courseId = store.blobPromptCourseId {
                BlobRequestCard(status: store.blobRequestStatusByCourse[courseId]) {
                    store.continueWithoutBlobs()
                }
            }
        }
        .onChange(of: store.currentRoundId) { oldId, newId in
            guard oldId != nil, newId == nil else { return }
            // Every way a round ends lands here: the watch's End Round, a round
            // ended on the phone and synced in, the lifecycle sweep. Detection
            // used to stop only from the Home button, so after any of those it
            // kept running — on 2026-09-07 six putts were detected and uploaded
            // up to half an hour after the round had ended. A Swing Test session
            // has no round and owns the detector itself, so it is left alone.
            if !SwingTestSession.shared.isRunning {
                SwingDetectionManager.shared.stopMonitoring()
            }
            if workoutManager.isWorkoutActive {
                dprint("⌚ [ContentView] Round ended, stopping workout")
                workoutManager.endWorkout()
            }
            store.blobPromptCourseId = nil
        }
    }
}

/// Where the iPhone is with this round's green detection. Shown at round start
/// whenever the course's blobs have to come from the phone, and dismissed only
/// by Continue or by the results arriving — so a phone that never started is
/// seen, not discovered holes later as a map with no greens on it.
private struct BlobRequestCard: View {
    let status: WatchDataStore.BlobRequestStatus?
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            switch status {
            case .unreachable, .queued:
                Image(systemName: "iphone.slash")
                    .font(.system(size: 28))
                    .foregroundColor(.orange)
                Text("iPhone unreachable for green detection")
                    .font(.system(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.red)
                Text("Failed")
                    .font(.system(size: 15, weight: .semibold))
            case .sent, .running, .none:
                Image(systemName: "iphone")
                    .font(.system(size: 28))
                    .foregroundColor(.green)
                ProgressView()
            }
            Button("Continue", action: onContinue)
                .padding(.top, 4)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
}
