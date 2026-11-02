import SwiftUI
import MapKit

// MARK: - Map Camera and Targets
//
// Where the map looks (tee to pin, fixed for the hole), target placement, and
// the crown offset.
extension ActiveRoundView {

    func toggleTargetPlacement() {
        isPlacingTarget.toggle()
        WKInterfaceDevice.current().play(.click)

        // When exiting target mode, reposition map
        if !isPlacingTarget {
            isMapFocused = false
            isMainViewFocused = true
            // Force immediate map update when exiting target mode
            DispatchQueue.main.async {
                restoreCalculatedMapPosition(force: true)
            }
        } else {
            restoreCalculatedMapPosition(force: true)
            isMapFocused = true
            isMainViewFocused = false
        }
    }

    func restoreCalculatedMapPosition(force: Bool = false) {
        if store.currentHole != nil {
            updateMapPosition(force: force)
        } else {
            updateNoHoleMapPosition()
        }
    }

    func updateMapPosition(force: Bool = false) {
        guard force || !isInteractiveMapMode else { return }

        guard let hole = store.currentHole,
              let holeCoord = hole.coordinate else { return }

        // Determine start coordinate based on view mode.
        // Full-view priority order:
        //   1. OSM hole centerline tee point (when available) — pinned tee
        //      box → flag is the most stable framing across the round and
        //      doesn't shift as strokes get added
        //   2. First recorded stroke — pre-OSM fallback for courses without
        //      hole data
        //   3. User location — last resort if there's no stroke and no OSM
        let startCoord: CLLocationCoordinate2D
        if isFullViewMode {
            let osmTee: CLLocationCoordinate2D? = {
                guard let courseId = store.currentRound?.courseId,
                      let osm = store.osmCourseData(forCourseId: courseId),
                      osm.tier == .full else { return nil }
                let match = osm.holes.first { Int($0.ref ?? "") == hole.number }
                return match?.centerline.first?.coordinate
            }()
            if let tee = osmTee {
                startCoord = tee
            } else if let first = firstStroke {
                startCoord = first.coordinate
            } else if let userLocation = locationManager.location {
                startCoord = userLocation.coordinate
            } else {
                return
            }
        } else if let userLocation = locationManager.location {
            startCoord = userLocation.coordinate
        } else {
            return
        }

        // Calculate bearing from start to hole
        let bearing = calculateBearing(from: startCoord, to: holeCoord)

        // Calculate distance
        let holeLocation = CLLocation(latitude: holeCoord.latitude, longitude: holeCoord.longitude)
        let startLocation = CLLocation(latitude: startCoord.latitude, longitude: startCoord.longitude)
        let distance = startLocation.distance(from: holeLocation)

        // Calculate center point - balanced between start and hole
        let centerLat = startCoord.latitude + (holeCoord.latitude - startCoord.latitude) * 0.45
        let centerLon = startCoord.longitude + (holeCoord.longitude - startCoord.longitude) * 0.5

        // Create camera oriented with start at bottom, hole at top
        let camera = MapCamera(
            centerCoordinate: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
            distance: max(distance * 2.5, 100), // Zoom to show both points with padding
            heading: bearing, // Rotate so hole is "up"
            pitch: 0
        )

        position = .camera(camera)
    }

    func updateNoHoleMapPosition() {
        guard let userLocation = locationManager.location else { return }

        // Show 500 yards (~457 meters) north and south from user
        // Total height is ~914 meters, so distance should be ~457 meters
        let camera = MapCamera(
            centerCoordinate: userLocation.coordinate,
            distance: 914, // ~1000 yards total view (500 N + 500 S)
            heading: 0, // North-aligned
            pitch: 0
        )

        position = .camera(camera)
    }

    func calculateBearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> CLLocationDirection {
        let lat1 = from.latitude * .pi / 180.0
        let lon1 = from.longitude * .pi / 180.0
        let lat2 = to.latitude * .pi / 180.0
        let lon2 = to.longitude * .pi / 180.0

        let dLon = lon2 - lon1

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let bearing = atan2(y, x)

        let bearingDegrees = bearing * 180.0 / .pi
        return (bearingDegrees + 360.0).truncatingRemainder(dividingBy: 360.0)
    }

    func calculateCrownOffset(screenHeight: CGFloat) {
        crownOffset = screenHeight * 0.1
    }
}
