import SwiftUI
import SwiftData
import CoreMotion

@main
struct GolfTrackerWatchApp: App {
    // These singletons manage their own lifetime — @ObservedObject is correct here.
    @ObservedObject private var connectivity = WatchConnectivityManager.shared
    @ObservedObject private var locationManager = LocationManager.shared
    @ObservedObject private var swingDetector = SwingDetectionManager.shared
    @AppStorage("hasSeenWatchOnboarding") private var hasSeenWatchOnboarding = false
    @Environment(\.scenePhase) private var scenePhase

    /// Same SwiftData schema as the iOS app — Realtime sync from Supabase will
    /// populate this container with the user's rounds/clubs/etc.
    let modelContainer: ModelContainer = {
        let schema = Schema([
            Course.self, Hole.self, Round.self, Stroke.self, Target.self,
            ClubData.self, ClubTypeData.self, ClubSet.self
        ])
        do {
            return try ModelContainer(for: schema)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    init() {
        // configure() needs to happen before singletons access the container.
        WatchDataStore.shared.configure(container: modelContainer)
        RealtimeSync.shared.configure(container: modelContainer)
        if let uid = WatchAuthSession.shared.currentUserId {
            RealtimeSync.shared.start(forUserId: uid)
        }
    }

    var body: some Scene {
        WindowGroup {
            if !hasSeenWatchOnboarding {
                WatchOnboardingView(hasSeenWatchOnboarding: $hasSeenWatchOnboarding)
            } else if swingDetector.motionAuthStatus == .denied || swingDetector.motionAuthStatus == .restricted {
                MotionAuthDeniedView()
            } else {
                ContentView()
            }
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
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
