import Foundation
import CoreLocation
import Combine
import WatchKit

/// Watches the user's GPS during an active round and auto-advances to the next
/// hole when they've genuinely walked off the green and toward the next tee.
///
/// **Trigger requires the user to have actually visited the green first.**
/// The "visited" gate is a point-in-polygon check against the OSM `golf=green`
/// polygon for the current hole — not a fudge-factor radius around a marker.
/// Once visited, the monitor advances when EITHER:
///
///   1. user is within `tee_box_threshold_yards` (10) of the next hole's tee point
///      (only when OSM provided tee data), OR
///   2. user is more than `green_left_threshold_yards` (40) from the current
///      hole's green marker (overall fallback)
///
/// Single-shot per hole — once advanced, the monitor won't re-fire for the
/// same hole until `resetForCurrentHole()` is called.
///
/// All distances in yards (single unit throughout). Real-world thresholds
/// chosen by Jared, not invented here.
final class AutoAdvanceMonitor: ObservableObject {
    static let shared = AutoAdvanceMonitor()

    /// User-visible toggle (also persisted across launches via UserDefaults).
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "autoAdvanceEnabled") }
    }

    /// Yards from the current green marker that counts as "left" — overall
    /// fallback trigger when the next-tee path isn't available or doesn't fire.
    var greenLeftThresholdYards: Double = 40
    /// Yards from the next hole's tee point that counts as "arriving at the
    /// next hole." Only used when OSM provides tee data for the next hole.
    var teeBoxThresholdYards: Double = 10

    private var cancellables = Set<AnyCancellable>()
    /// Set of hole numbers we've already auto-advanced from. Cleared per-hole
    /// by `resetForCurrentHole()` if user manually navigates back.
    private var advancedFromHoleNumber: Int?
    /// Set of hole numbers the user's GPS has been geometrically inside the
    /// green polygon for. Persists across the lifetime of this round; cleared
    /// when the round changes.
    private var visitedGreenHoles: Set<Int> = []
    private var visitedRoundId: UUID?

    private init() {
        if UserDefaults.standard.object(forKey: "autoAdvanceEnabled") != nil {
            self.enabled = UserDefaults.standard.bool(forKey: "autoAdvanceEnabled")
        } else {
            self.enabled = true
        }
        wireLocationUpdates()
    }

    private func wireLocationUpdates() {
        LocationManager.shared.$location
            .compactMap { $0 }
            .throttle(for: .seconds(2), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] loc in
                self?.evaluate(at: loc.coordinate)
            }
            .store(in: &cancellables)
    }

    /// Re-arms the monitor — call when the user manually navigates to a hole
    /// (so re-leaving that hole can fire again).
    func resetForCurrentHole() {
        advancedFromHoleNumber = nil
    }

    private func evaluate(at coordinate: CLLocationCoordinate2D) {
        guard enabled else { return }
        let store = WatchDataStore.shared
        guard let round = store.currentRound else { return }

        // New round → wipe visited tracking.
        if visitedRoundId != round.id {
            visitedRoundId = round.id
            visitedGreenHoles.removeAll()
            advancedFromHoleNumber = nil
        }

        let idx = round.currentHoleIndex
        guard idx >= 0, idx < round.holes.count else { return }
        let currentHole = round.holes[idx]
        // Last hole — nothing to advance to.
        guard idx + 1 < round.holes.count else { return }
        let nextHole = round.holes[idx + 1]
        guard let currentGreenMarker = currentHole.coordinate else { return }
        // Skip if we've already advanced from this hole.
        if advancedFromHoleNumber == currentHole.number { return }

        // Pull OSM data for this round's course (cached in WatchDataStore).
        // We need it for both the visited check (green polygon) and the
        // next-tee trigger.
        let osm = store.osmCourseData(forCourseId: round.courseId)
        let currentOSMHole = osm?.holes.first { Int($0.ref ?? "") == currentHole.number }
        let nextOSMHole = osm?.holes.first { Int($0.ref ?? "") == nextHole.number }
        let currentGreenPolygon = currentOSMHole.flatMap { osm?.greenPolygon(for: $0) }

        // === Visited gate: did the user's GPS land inside the green polygon? ===
        if let polygon = currentGreenPolygon, polygon.contains(coordinate) {
            visitedGreenHoles.insert(currentHole.number)
        }
        guard visitedGreenHoles.contains(currentHole.number) else {
            // Never visited the green for this hole — don't advance.
            return
        }

        // === Trigger A: within tee_box_threshold_yards of next hole's tee point ===
        if let nextTee = nextOSMHole?.teePoint {
            let teeLoc = CLLocation(latitude: nextTee.latitude, longitude: nextTee.longitude)
            let userLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let yardsToTee = userLoc.distance(from: teeLoc) * 1.09361
            if yardsToTee <= teeBoxThresholdYards {
                fire(from: currentHole, to: nextHole, reason: "near next tee (\(Int(yardsToTee))yd)")
                return
            }
        }

        // === Trigger B: more than green_left_threshold_yards from current green marker ===
        let userLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let greenLoc = CLLocation(latitude: currentGreenMarker.latitude, longitude: currentGreenMarker.longitude)
        let yardsFromGreen = userLoc.distance(from: greenLoc) * 1.09361
        if yardsFromGreen >= greenLeftThresholdYards {
            fire(from: currentHole, to: nextHole, reason: "left green (\(Int(yardsFromGreen))yd)")
            return
        }
    }

    private func fire(from currentHole: Hole, to nextHole: Hole, reason: String) {
        let store = WatchDataStore.shared
        advancedFromHoleNumber = currentHole.number
        WKInterfaceDevice.current().play(.success)
        if !(store.currentRound?.isHoleCompleted(currentHole.number) ?? true) {
            store.completeHole(holeNumber: currentHole.number)
        }
        store.navigateToNextHole()
        dprint("⌚ [AutoAdvance] Hole \(currentHole.number) → \(nextHole.number) — \(reason)")
    }
}
