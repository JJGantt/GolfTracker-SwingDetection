import SwiftUI

@main
struct GolfTrackerWatchApp: App {
    // These singletons manage their own lifetime — @ObservedObject is correct here.
    @ObservedObject private var connectivity = WatchConnectivityManager.shared
    @ObservedObject private var locationManager = LocationManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
