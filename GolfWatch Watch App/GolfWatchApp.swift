import SwiftUI
import CoreMotion

@main
struct GolfTrackerWatchApp: App {
    // These singletons manage their own lifetime — @ObservedObject is correct here.
    @ObservedObject private var connectivity = WatchConnectivityManager.shared
    @ObservedObject private var locationManager = LocationManager.shared
    @ObservedObject private var swingDetector = SwingDetectionManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            if swingDetector.motionAuthStatus == .denied || swingDetector.motionAuthStatus == .restricted {
                MotionAuthDeniedView()
            } else {
                ContentView()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Re-check whenever app comes back to foreground (e.g. after user dismisses the
                // system permission dialog or changes privacy settings).
                swingDetector.checkAndRequestMotionAuthorization()
            }
        }
    }
}

struct MotionAuthDeniedView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.title2)

            Text("Motion Access Denied")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("Swing detection requires motion permission. On your iPhone go to Watch app > Privacy > Motion & Fitness and enable access.")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Button("Re-check") {
                SwingDetectionManager.shared.checkAndRequestMotionAuthorization()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding()
    }
}
