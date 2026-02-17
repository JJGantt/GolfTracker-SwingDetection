import SwiftUI

@main
struct GolfTrackerWatchApp: App {
    // Initialize connectivity on app launch
    @StateObject private var connectivity = WatchConnectivityManager.shared
    @StateObject private var locationManager = LocationManager.shared

    init() {
        SwingDetectionManager.shared.requestNotificationPermission()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
