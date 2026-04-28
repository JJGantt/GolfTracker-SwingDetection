import Foundation
import CoreLocation
import Combine
import WatchKit

/// Watches the user's GPS during an active round and auto-advances to the next
/// hole when they've clearly walked off the previous green. Only active when
/// the next hole's coordinate is known (Tier-1 OSM round, or any round in its
/// second-and-later play where the user has previously placed every hole).
///
/// Trigger requires ALL of:
///   - Distance from previous-hole green > `advanceDistanceYards` (default 50yd)
///   - Time since last stroke on previous hole > `minSecondsSinceLastStroke`
///   - Distance to next anchor is closer than to previous anchor
///   - We haven't already triggered for this hole transition
///
/// Single-shot per hole — once advanced, the monitor won't re-fire for the
/// same hole until the user manually navigates back.
final class AutoAdvanceMonitor: ObservableObject {
    static let shared = AutoAdvanceMonitor()

    /// User-visible toggle (also persisted across launches via UserDefaults).
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "autoAdvanceEnabled") }
    }

    /// Tunables
    var advanceDistanceYards: Double = 50
    var minSecondsSinceLastStroke: TimeInterval = 5

    private var cancellables = Set<AnyCancellable>()
    private var advancedFromHoleNumber: Int?

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
        let idx = round.currentHoleIndex
        guard idx >= 0, idx < round.holes.count else { return }
        let currentHole = round.holes[idx]
        // Only proceed if both current and next holes have known coordinates.
        guard let currentGreen = currentHole.coordinate else { return }
        guard idx + 1 < round.holes.count else { return }  // last hole — nothing to advance to
        let nextHole = round.holes[idx + 1]
        guard let nextAnchor = nextHole.coordinate else { return }
        // Skip if we've already advanced from this hole and the user hasn't reset.
        if advancedFromHoleNumber == currentHole.number { return }

        // Distance from previous green.
        let userLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let greenLoc = CLLocation(latitude: currentGreen.latitude, longitude: currentGreen.longitude)
        let nextLoc = CLLocation(latitude: nextAnchor.latitude, longitude: nextAnchor.longitude)
        let metersFromPrev = userLoc.distance(from: greenLoc)
        let metersToNext = userLoc.distance(from: nextLoc)
        let yardsFromPrev = metersFromPrev * 1.09361
        guard yardsFromPrev > advanceDistanceYards else { return }
        // Heading toward next hole?
        guard metersToNext < metersFromPrev else { return }
        // Time-since-last-stroke gate.
        let lastStrokeT = round.strokes
            .filter { $0.holeNumber == currentHole.number }
            .map { $0.timestamp }
            .max()
        if let last = lastStrokeT, Date().timeIntervalSince(last) < minSecondsSinceLastStroke {
            return
        }

        // All gates passed — advance.
        advancedFromHoleNumber = currentHole.number
        WKInterfaceDevice.current().play(.success)
        // Mark previous hole completed if it isn't already, then navigate.
        if !round.isHoleCompleted(currentHole.number) {
            store.completeHole(holeNumber: currentHole.number)
        }
        store.navigateToNextHole()
        dprint("⌚ [AutoAdvance] Advanced to hole \(nextHole.number) — \(Int(yardsFromPrev))yd from prev green")
    }
}
