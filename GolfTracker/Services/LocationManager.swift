import Foundation
import CoreLocation
import Combine

/// LocationManager publishes via the classic `ObservableObject` /
/// `@Published` pattern. We previously tried the `@Observable` macro for
/// finer-grained per-property tracking, but that turned out to make
/// `ActiveRoundView` re-render more aggressively, not less, because the
/// view body reads many LocationManager properties (`location`, `heading`,
/// `gpsPowerMode`) and each became its own dependency edge. Coarse-grained
/// `objectWillChange` is, in practice, what works — SwiftUI batches
/// multiple @Published mutations into a single re-eval per runloop tick.
class LocationManager: NSObject, ObservableObject {
    static let shared = LocationManager()
    static let testCoordinate = CLLocationCoordinate2D(
        latitude: 30.285357365597697,
        longitude: -81.74623642434663
    )

    private let locationManager = CLLocationManager()

    @Published var location: CLLocation?
    @Published var heading: CLLocationDirection?

    /// Rolling buffer of recent user GPS points, used to draw a fading
    /// breadcrumb trail behind the user marker on the active-round and
    /// hole-placement maps. Newest entry is last. Spacing-throttled so a
    /// stationary user doesn't burn the whole buffer on jitter.
    struct Breadcrumb: Identifiable {
        let id = UUID()
        let coordinate: CLLocationCoordinate2D
        let timestamp: Date
    }
    @Published private(set) var breadcrumbs: [Breadcrumb] = []
    private let breadcrumbMaxCount = 60
    private let breadcrumbMinSpacingMeters: CLLocationDistance = 3

    private func appendBreadcrumb(_ loc: CLLocation) {
        if let last = breadcrumbs.last {
            let prev = CLLocation(latitude: last.coordinate.latitude,
                                  longitude: last.coordinate.longitude)
            if loc.distance(from: prev) < breadcrumbMinSpacingMeters { return }
        }
        breadcrumbs.append(Breadcrumb(coordinate: loc.coordinate, timestamp: Date()))
        if breadcrumbs.count > breadcrumbMaxCount {
            breadcrumbs.removeFirst(breadcrumbs.count - breadcrumbMaxCount)
        }
    }
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var errorMessage: String?
    @Published var isTestModeEnabled: Bool = false
    enum GPSPowerMode: String {
        case full       // kCLLocationAccuracyBest, 1m filter
        case moderate   // kCLLocationAccuracyNearestTenMeters, 10m filter
    }

    @Published var gpsPowerMode: GPSPowerMode = .full

    /// Combine publisher for non-view subscribers (background watchers like
    /// `AutoAdvanceMonitor` that use throttling/sinks). View code reads
    /// the `location` property directly via `@ObservedObject`/`@StateObject`
    /// and gets updates through the standard ObservableObject path.
    let locationPublisher = PassthroughSubject<CLLocation, Never>()

    /// User-controlled simulated location during test mode. When nil but
    /// test mode is on, falls back to the static testCoordinate so the
    /// app has *something* to use. Updated by `TestModeService` from
    /// Supabase Realtime when the iPhone Test Mode view writes a new pin.
    private var simulatedTestLocation: CLLocation?

    private var forcedTestLocation: CLLocation {
        simulatedTestLocation
            ?? CLLocation(latitude: Self.testCoordinate.latitude, longitude: Self.testCoordinate.longitude)
    }

    /// Push a new simulated location into the running app. Updates
    /// `location` and fires the `locationPublisher` so AutoAdvanceMonitor's
    /// throttled subscriber re-evaluates. Called from TestModeService when
    /// an inbound DB change lands. No-op when test mode isn't enabled —
    /// caller should flip test mode on first via `setTestModeEnabled(true)`.
    func applyTestLocation(_ coord: CLLocationCoordinate2D) {
        let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        simulatedTestLocation = loc
        guard isTestModeEnabled else { return }
        location = loc
        appendBreadcrumb(loc)
        locationPublisher.send(loc)
        errorMessage = nil
    }

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 1 // Update every 1 meter
        // Heading is no longer used by the round-play UI — the user marker
        // renders as a non-rotating dot and aim direction will be driven
        // by the OSM hole centerline when that lands. Skipping headingFilter
        // setup and `startUpdatingHeading()` saves the compass radio cost.

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
        // Don't bail on isTestModeEnabled here. Permission and live-GPS
        // tracking are separate — we can hold the OS-level permission
        // even while currently sourcing location from a test simulator,
        // and the user shouldn't be blocked from completing onboarding
        // just because test mode happens to be on.
        #if os(iOS) || os(watchOS)
        locationManager.requestWhenInUseAuthorization()
        #elseif os(macOS)
        // macOS doesn't require explicit permission request
        #endif
    }

    func setTestModeEnabled(_ enabled: Bool) {
        // Synchronous on whatever thread the caller is on. Used to dispatch
        // async to avoid SwiftUI "Publishing changes from within view
        // updates" warnings, but our actual call sites are background Tasks
        // (TestModeService.applyState / setTestModeEnabled toggle), not view
        // updates — and the async dispatch was creating a window where
        // isTestModeEnabled was still `false` when downstream code (like
        // ActiveRoundView.handleViewAppear → startTracking) ran, causing
        // real GPS to spin up and overwrite the simulated location.
        isTestModeEnabled = enabled
        if enabled {
            locationManager.stopUpdatingLocation()
            let forced = forcedTestLocation
            location = forced
            errorMessage = nil
            // Fire the Combine publisher so AutoAdvanceMonitor and any
            // other locationPublisher subscribers re-evaluate against the
            // simulated coord, same as a real GPS update.
            locationPublisher.send(forced)
            dprint("[LocationManager] Test mode ON: forcing location to \(forced.coordinate.latitude), \(forced.coordinate.longitude)")
        } else {
            simulatedTestLocation = nil
            dprint("[LocationManager] Test mode OFF: resuming live GPS")
            startTracking()
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

        dprint("[LocationManager] startTracking called - isAuthorized: \(isAuthorized), status: \(authorizationStatus.rawValue)")

        guard isAuthorized else {
            errorMessage = "Location permission not granted"
            dprint("[LocationManager] NOT authorized, skipping location updates")
            return
        }

        dprint("[LocationManager] Starting location updates")
        locationManager.startUpdatingLocation()
        // Heading updates intentionally NOT started — see init() note.
    }

    func stopTracking() {
        locationManager.stopUpdatingLocation()
        gpsPowerMode = .full
    }

    func setGPSPowerMode(_ mode: GPSPowerMode) {
        guard mode != gpsPowerMode, !isTestModeEnabled else { return }
        gpsPowerMode = mode

        switch mode {
        case .full:
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.distanceFilter = 1
            locationManager.startUpdatingLocation()
            dprint("[LocationManager] GPS: full (best accuracy, 1m filter)")

        case .moderate:
            locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            locationManager.distanceFilter = 10
            locationManager.startUpdatingLocation()
            dprint("[LocationManager] GPS: moderate (10m accuracy, 10m filter)")
        }
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
        dprint("[LocationManager] Authorization changed to: \(authorizationStatus.rawValue)")

        #if os(iOS) || os(watchOS)
        let authorized = authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
        #elseif os(macOS)
        let authorized = authorizationStatus == .authorizedAlways
        #endif

        if authorized {
            dprint("[LocationManager] Authorization granted, starting location tracking")
            startTracking()
        } else if authorizationStatus == .denied || authorizationStatus == .restricted {
            dprint("[LocationManager] Authorization denied or restricted")
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
        dprint("[LocationManager] Got location update: \(newLocation.coordinate.latitude), \(newLocation.coordinate.longitude)")
        location = newLocation
        appendBreadcrumb(newLocation)
        locationPublisher.send(newLocation)
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
