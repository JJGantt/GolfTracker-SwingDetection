import Foundation
import CoreLocation
import Combine

class LocationManager: NSObject, ObservableObject {
    static let shared = LocationManager()
    static let testCoordinate = CLLocationCoordinate2D(
        latitude: 30.285357365597697,
        longitude: -81.74623642434663
    )

    private let locationManager = CLLocationManager()

    @Published var location: CLLocation?
    @Published var heading: CLLocationDirection?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var errorMessage: String?
    @Published var isTestModeEnabled: Bool = false
    @Published var isLowPowerMode: Bool = false
    private var lowPowerTimer: Timer?

    private var forcedTestLocation: CLLocation {
        CLLocation(latitude: Self.testCoordinate.latitude, longitude: Self.testCoordinate.longitude)
    }

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 1 // Update every 1 meter
        locationManager.headingFilter = 5 // Update every 5 degrees

        // Enable background location updates (necessary for watchOS when screen is off)
        #if os(iOS) || os(watchOS)
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.activityType = .fitness // Golf is a fitness activity
        #endif

        #if os(iOS)
        locationManager.pausesLocationUpdatesAutomatically = false
        #endif

        #if targetEnvironment(simulator)
        // Set a default location for simulator testing
        location = CLLocation(latitude: 37.7749, longitude: -122.4194)
        #endif
    }

    func requestPermission() {
        if isTestModeEnabled {
            return
        }
        #if os(iOS) || os(watchOS)
        locationManager.requestWhenInUseAuthorization()
        #elseif os(macOS)
        // macOS doesn't require explicit permission request
        #endif
    }

    func setTestModeEnabled(_ enabled: Bool) {
        // Dispatch to avoid "Publishing changes from within view updates" when
        // called from SwiftUI .onChange callbacks.
        let apply = {
            self.isTestModeEnabled = enabled

            if enabled {
                self.locationManager.stopUpdatingLocation()
                #if os(iOS) || os(watchOS)
                self.locationManager.stopUpdatingHeading()
                #endif

                self.location = self.forcedTestLocation
                self.heading = 0
                self.errorMessage = nil
                print("[LocationManager] Test mode ON: forcing location to \(self.forcedTestLocation.coordinate.latitude), \(self.forcedTestLocation.coordinate.longitude)")
            } else {
                print("[LocationManager] Test mode OFF: resuming live GPS")
                self.startTracking()
            }
        }

        if Thread.isMainThread {
            DispatchQueue.main.async { apply() }
        } else {
            apply()
        }
    }

    func startTracking() {
        if isTestModeEnabled {
            location = forcedTestLocation
            heading = 0
            errorMessage = nil
            return
        }

        #if os(iOS) || os(watchOS)
        let isAuthorized = authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
        #elseif os(macOS)
        let isAuthorized = authorizationStatus == .authorizedAlways
        #endif

        print("[LocationManager] startTracking called - isAuthorized: \(isAuthorized), status: \(authorizationStatus.rawValue)")

        guard isAuthorized else {
            errorMessage = "Location permission not granted"
            print("[LocationManager] NOT authorized, skipping location updates")
            return
        }

        print("[LocationManager] Starting location updates")
        locationManager.startUpdatingLocation()

        #if os(iOS) || os(watchOS)
        if CLLocationManager.headingAvailable() {
            locationManager.startUpdatingHeading()
        }
        #endif
    }

    func stopTracking() {
        locationManager.stopUpdatingLocation()

        #if os(iOS) || os(watchOS)
        locationManager.stopUpdatingHeading()
        #endif
        exitLowPowerMode()
    }

    func enterLowPowerMode() {
        guard !isLowPowerMode, !isTestModeEnabled else { return }
        isLowPowerMode = true
        locationManager.stopUpdatingLocation()
        // Single fix immediately, then every 30s
        locationManager.requestLocation()
        lowPowerTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.locationManager.requestLocation()
        }
        print("[LocationManager] Entered low power mode (30s periodic fixes)")
    }

    func exitLowPowerMode() {
        guard isLowPowerMode else { return }
        lowPowerTimer?.invalidate()
        lowPowerTimer = nil
        isLowPowerMode = false
        locationManager.startUpdatingLocation()
        print("[LocationManager] Exited low power mode (continuous updates)")
    }

    func distance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance? {
        guard let location = location else { return nil }
        let targetLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return location.distance(from: targetLocation)
    }

    func formattedDistance(to coordinate: CLLocationCoordinate2D?) -> String {
        guard let coordinate = coordinate else {
            return "No flag placed"
        }
        guard let distance = distance(to: coordinate) else {
            return "Searching for GPS..."
        }

        // Convert meters to yards
        let yards = distance * 1.09361

        if yards < 1000 {
            return String(format: "%.0f yards", yards)
        } else {
            let miles = yards / 1760
            return String(format: "%.2f miles", miles)
        }
    }

    /// Get current location synchronously (uses last known location if available)
    func getCurrentLocation() -> CLLocation? {
        if isTestModeEnabled {
            return forcedTestLocation
        }

        // First try the published location (most recent)
        if let loc = location {
            return loc
        }
        // Fall back to CLLocationManager's last known location
        return locationManager.location
    }
}

extension LocationManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        print("[LocationManager] Authorization changed to: \(authorizationStatus.rawValue)")

        #if os(iOS) || os(watchOS)
        let authorized = authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
        #elseif os(macOS)
        let authorized = authorizationStatus == .authorizedAlways
        #endif

        if authorized {
            print("[LocationManager] Authorization granted, starting location tracking")
            startTracking()
        } else if authorizationStatus == .denied || authorizationStatus == .restricted {
            print("[LocationManager] Authorization denied or restricted")
            errorMessage = "Location access denied. Please enable in Settings."
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if isTestModeEnabled {
            location = forcedTestLocation
            errorMessage = nil
            return
        }

        guard let newLocation = locations.last else { return }
        print("[LocationManager] Got location update: \(newLocation.coordinate.latitude), \(newLocation.coordinate.longitude)")
        location = newLocation
        errorMessage = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        if isTestModeEnabled {
            heading = 0
            return
        }

        // Use true heading if available, otherwise use magnetic heading
        if newHeading.trueHeading >= 0 {
            heading = newHeading.trueHeading
        } else {
            heading = newHeading.magneticHeading
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if isTestModeEnabled {
            return
        }
        errorMessage = "Failed to get location: \(error.localizedDescription)"
    }
}
