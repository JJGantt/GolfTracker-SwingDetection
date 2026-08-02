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

                Text("Two permissions make swing detection work best. You can start a round without them.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                primer(
                    title: "Motion",
                    body: motionBody,
                    granted: swingDetector.motionAuthStatus == .authorized,
                    // The system prompt can only ever appear once. Once the
                    // status is denied there is nothing an in-app button can
                    // do — and watchOS has no Settings deep link — so hide the
                    // button and tell the user where to go instead of leaving
                    // a control that silently does nothing.
                    actionable: swingDetector.motionAuthStatus == .notDetermined,
                    action: requestMotion
                )

                primer(
                    title: "HealthKit",
                    body: "Unlocks the 800 Hz motion stream that powers precise swing detection.",
                    granted: workoutManager.healthKitAuthorizationStatus == .sharingAuthorized,
                    actionable: true,
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

    /// Motion & Fitness gates `CMPedometer` (the step count behind the
    /// practice-swing gate), NOT the swing detector itself — `CMMotionManager`
    /// and `CMBatchedSensorManager` need no such grant on watchOS. So a denial
    /// costs practice-swing filtering, not detection, and shouldn't read like
    /// a dead end.
    private var motionBody: String {
        switch swingDetector.motionAuthStatus {
        case .denied, .restricted:
            return "Denied. Enable it on your iPhone: Watch app → Privacy → Motion & Fitness. Swings are still detected without it."
        default:
            return "Reads accelerometer and rotation data to detect each swing."
        }
    }

    @ViewBuilder
    private func primer(title: String, body: String, granted: Bool,
                        actionable: Bool, action: @escaping () -> Void) -> some View {
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
            if !granted && actionable {
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
