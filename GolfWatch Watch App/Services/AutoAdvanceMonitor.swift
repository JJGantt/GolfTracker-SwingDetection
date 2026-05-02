import Foundation
import CoreLocation
import Combine
import WatchKit

/// Watches the user's GPS during an active round and auto-advances to the
/// next hole when they've putted out and walked off the green.
///
/// State model: a single ephemeral `currentHoleEnteredAt` timestamp. It
/// resets to `Date()` on every `currentHoleIndex` change in any direction
/// (forward auto-advance, manual back-nav, manual forward-nav, fresh load).
/// There is no per-hole memory beyond that — strokes themselves live in
/// `round.strokes` and we filter by timestamp.
///
/// Gates:
///   1. **Putted-since-arrival**: there exists a putter stroke for the
///      current hole with `timestamp > currentHoleEnteredAt`. Old putts
///      from a prior visit (back-nav case) don't count.
///   2. **Distance**: user is `>= greenLeftThresholdYards` (default 10) from
///      the green polygon perimeter.
///   3. **Bonus accelerator**: when OSM provides next-hole tee data, also
///      fires when user is within `teeBoxThresholdYards` (10) of the next
///      tee centerline — same putted-since-arrival gate applies.
///
/// All distances in yards. Thresholds chosen by Jared, not invented here.
final class AutoAdvanceMonitor: ObservableObject {
    static let shared = AutoAdvanceMonitor()

    /// User-visible toggle (also persisted across launches via UserDefaults).
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "autoAdvanceEnabled") }
    }

    /// Yards beyond the **green polygon perimeter** that counts as "left."
    /// Read from UserDefaults each evaluation so the iOS Settings → Developer
    /// slider can tune it live.
    static let greenLeftThresholdYardsKey = "autoAdvanceGreenLeftThresholdYards"
    var greenLeftThresholdYards: Double {
        let v = UserDefaults.standard.double(forKey: Self.greenLeftThresholdYardsKey)
        return v > 0 ? v : 10
    }
    /// Yards from the next hole's tee point that counts as "arriving at the
    /// next hole." Only used when OSM provides tee data for the next hole.
    var teeBoxThresholdYards: Double = 10

    private var cancellables = Set<AnyCancellable>()
    /// Timestamp the user arrived at the current hole. Resets on every
    /// hole-index change. The putt-gate filters strokes by `> this`.
    private var currentHoleEnteredAt: Date = Date()
    private var lastSeenHoleIndex: Int?
    private var lastSeenRoundId: UUID?

    private init() {
        if UserDefaults.standard.object(forKey: "autoAdvanceEnabled") != nil {
            self.enabled = UserDefaults.standard.bool(forKey: "autoAdvanceEnabled")
        } else {
            self.enabled = true
        }
        wireLocationUpdates()
    }

    private func wireLocationUpdates() {
        LocationManager.shared.locationPublisher
            .throttle(for: .seconds(2), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] loc in
                self?.evaluate(at: loc.coordinate)
            }
            .store(in: &cancellables)
    }

    private func evaluate(at coordinate: CLLocationCoordinate2D) {
        guard enabled else { return }
        let store = WatchDataStore.shared
        guard let round = store.currentRound else { return }

        // SwiftData @Relationship arrays do NOT preserve order — sort by
        // hole number explicitly. Without this, round.holes[idx] returns
        // some random hole and we'd evaluate against the wrong green.
        let sortedHoles = round.holes.sorted { $0.number < $1.number }
        let idx = round.currentHoleIndex
        guard idx >= 0, idx < sortedHoles.count else { return }
        let currentHole = sortedHoles[idx]
        let hasNextHole = idx + 1 < sortedHoles.count
        let nextHole: Hole? = hasNextHole ? sortedHoles[idx + 1] : nil
        guard let currentGreenMarker = currentHole.coordinate else { return }

        // Reset the arrival timestamp on any hole-index or round change.
        // Single source of state — back-nav, forward-nav, new round, all
        // funnel through this one assignment. Prior putts are now "before
        // arrival" and won't satisfy the putt gate until the user putts
        // again from this visit.
        if lastSeenRoundId != round.id || lastSeenHoleIndex != idx {
            currentHoleEnteredAt = Date()
            lastSeenRoundId = round.id
            lastSeenHoleIndex = idx
        }

        // === Putt-since-arrival gate ===
        // Filters by timestamp so back-nav doesn't satisfy this just because
        // an old putt exists for the hole.
        let arrivalTs = currentHoleEnteredAt
        let hasPuttedSinceArrival = round.strokes.contains { (stroke: Stroke) -> Bool in
            guard stroke.holeNumber == currentHole.number else { return false }
            guard stroke.timestamp > arrivalTs else { return false }
            guard let club = store.availableClubs.first(where: { $0.id == stroke.clubId }) else { return false }
            return store.getTypeName(for: club) == "Putt"
        }
        guard hasPuttedSinceArrival else { return }

        // OSM data (if any) — used for the bonus next-tee accelerator only.
        let osm = store.osmCourseData(forCourseId: round.courseId)
        let nextOSMHole = nextHole.flatMap { nh in osm?.holes.first { Int($0.ref ?? "") == nh.number } }

        // Source-agnostic green polygon — same lookup the round-play UI uses.
        let currentGreenBlob = store.filteredGreenCandidates(for: round.courseId)
            .first { $0.contains(currentGreenMarker) }

        // === Trigger A: near next hole's tee centerline ===
        if let next = nextHole, let nextTee = nextOSMHole?.teePoint {
            let line = nextOSMHole?.centerline ?? []
            let userLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let yardsToLine: Double = {
                if line.count >= 2 {
                    let a = line[0].coordinate
                    let b = line[1].coordinate
                    return distanceMetersToSegment(point: coordinate, segA: a, segB: b) * 1.09361
                }
                let teeLoc = CLLocation(latitude: nextTee.latitude, longitude: nextTee.longitude)
                return userLoc.distance(from: teeLoc) * 1.09361
            }()
            if yardsToLine <= teeBoxThresholdYards {
                fire(from: currentHole, to: next, reason: "near next tee (\(Int(yardsToLine))yd)")
                return
            }
        }

        // === Trigger B: ≥ greenLeftThresholdYards perpendicular from polygon edge ===
        // Inside polygon → 0yd. Outside → min perpendicular distance to any
        // edge segment (not vertex). Vertex-distance was wrong on typical
        // 25–30yd greens with 5–7yd vertex spacing — min-vertex from the
        // pin can exceed 10yd while the user is still standing on the green,
        // so the gate fired from the cup. Edge-distance via the existing
        // `distanceMetersToSegment` helper measures actual off-green distance.
        let userLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let yardsFromEdge: Double = {
            if let blob = currentGreenBlob, !blob.polygon.isEmpty {
                if blob.contains(coordinate) { return 0 }
                let poly = blob.polygon
                var minMeters = Double.greatestFiniteMagnitude
                for i in 0..<poly.count {
                    let a = poly[i]
                    let b = poly[(i + 1) % poly.count]
                    let d = distanceMetersToSegment(point: coordinate, segA: a, segB: b)
                    if d < minMeters { minMeters = d }
                }
                return minMeters * 1.09361
            } else {
                let greenLoc = CLLocation(latitude: currentGreenMarker.latitude, longitude: currentGreenMarker.longitude)
                return userLoc.distance(from: greenLoc) * 1.09361
            }
        }()
        if yardsFromEdge >= greenLeftThresholdYards {
            if let next = nextHole {
                fire(from: currentHole, to: next, reason: "left green (\(Int(yardsFromEdge))yd from edge)")
            } else {
                fireAddNext(from: currentHole, reason: "left green (\(Int(yardsFromEdge))yd from edge), no next hole")
            }
            return
        }
    }

    /// Geometry-mode case: no next hole exists yet. Creates one (no
    /// coordinate) so HolePlacementView's `needsFlagPlacement` flow takes over.
    private func fireAddNext(from currentHole: Hole, reason: String) {
        let store = WatchDataStore.shared
        WKInterfaceDevice.current().play(.success)
        if !(store.currentRound?.isHoleCompleted(currentHole.number) ?? true) {
            store.completeHole(holeNumber: currentHole.number)
        }
        store.addNextHole()
        dprint("⌚ [AutoAdvance] Hole \(currentHole.number) → addNext — \(reason)")
    }

    /// Perpendicular distance in meters from `point` to segment AB. Uses an
    /// equirectangular local projection — within a single hole the flat-earth
    /// approximation is well below GPS noise.
    private func distanceMetersToSegment(point: CLLocationCoordinate2D,
                                         segA: CLLocationCoordinate2D,
                                         segB: CLLocationCoordinate2D) -> Double {
        let metersPerDegLat = 111_000.0
        let cosLat = cos(point.latitude * .pi / 180.0)
        let metersPerDegLon = metersPerDegLat * cosLat
        let px = (point.longitude - segA.longitude) * metersPerDegLon
        let py = (point.latitude - segA.latitude) * metersPerDegLat
        let bx = (segB.longitude - segA.longitude) * metersPerDegLon
        let by = (segB.latitude - segA.latitude) * metersPerDegLat
        let lenSq = bx * bx + by * by
        guard lenSq > 0 else { return sqrt(px * px + py * py) }
        let t = max(0.0, min(1.0, (px * bx + py * by) / lenSq))
        let closestX = t * bx
        let closestY = t * by
        let dx = px - closestX
        let dy = py - closestY
        return sqrt(dx * dx + dy * dy)
    }

    private func fire(from currentHole: Hole, to nextHole: Hole, reason: String) {
        let store = WatchDataStore.shared
        WKInterfaceDevice.current().play(.success)
        if !(store.currentRound?.isHoleCompleted(currentHole.number) ?? true) {
            store.completeHole(holeNumber: currentHole.number)
        }
        store.navigateToNextHole()
        dprint("⌚ [AutoAdvance] Hole \(currentHole.number) → \(nextHole.number) — \(reason)")
    }
}
