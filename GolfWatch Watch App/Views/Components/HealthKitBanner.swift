import SwiftUI
import HealthKit

struct HealthKitBanner: View {
    @ObservedObject var workoutManager: WorkoutManager = .shared

    var body: some View {
        if workoutManager.healthKitAuthorizationStatus == .sharingDenied {
            VStack(alignment: .leading, spacing: 4) {
                Text("HealthKit required")
                    .font(.caption.bold())
                Text("Swing detection needs HealthKit. Enable it in the Watch app on iPhone: My Watch → Health → Apps → GolfWatch.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.25))
            )
        }
    }
}
