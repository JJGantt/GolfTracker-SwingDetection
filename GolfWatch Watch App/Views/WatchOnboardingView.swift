import SwiftUI
import HealthKit
import CoreMotion

struct WatchOnboardingView: View {
    @Binding var hasSeenWatchOnboarding: Bool
    @ObservedObject private var workoutManager = WorkoutManager.shared
    @ObservedObject private var swingDetector = SwingDetectionManager.shared
    @State private var requestedMotion = false
    @State private var requestedHealthKit = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Welcome")
                    .font(.headline)

                Text("GolfTracker needs two permissions on your Watch for swing detection to work.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                primer(
                    title: "Motion",
                    body: "Reads accelerometer and rotation data to detect each swing.",
                    granted: swingDetector.motionAuthStatus == .authorized,
                    action: requestMotion
                )

                primer(
                    title: "HealthKit",
                    body: "Unlocks the 800 Hz motion stream that powers precise swing detection.",
                    granted: workoutManager.healthKitAuthorizationStatus == .sharingAuthorized,
                    action: requestHealthKit
                )

                Button(action: { hasSeenWatchOnboarding = true }) {
                    Text("Continue")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .padding(.top, 4)
            }
            .padding(.horizontal, 8)
        }
    }

    private func requestMotion() {
        requestedMotion = true
        swingDetector.checkAndRequestMotionAuthorization()
    }

    private func requestHealthKit() {
        requestedHealthKit = true
        workoutManager.requestAuthorization { _, _ in }
    }

    @ViewBuilder
    private func primer(title: String, body: String, granted: Bool, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.bold())
                Spacer()
                if granted {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                }
            }
            Text(body)
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !granted {
                Button(action: action) {
                    Text("Enable")
                        .font(.caption2.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.2)))
    }
}
