import Foundation
import CoreLocation
import SwiftData

// Adding, moving and navigating holes in the current round.
extension WatchDataStore {

    // MARK: - Hole Management

    func addNextHole() {
        ClientEventLogger.log("addNextHole.start")
        guard let round = currentRound, let context = context else {
            ClientEventLogger.log("addNextHole.guardFailed")
            return
        }
        let nextHoleNumber = (round.holes.map(\.number).max() ?? 0) + 1
        let holeId = Hole.roundHoleId(roundId: round.id, number: nextHoleNumber)
        // If canonical resolution covers this hole_number (this user's
        // own pick or cross-user voting threshold), pre-populate so
        // HolePlacementView is skipped.
        let canonical = canonicalHolePlacementsByCourse[round.courseId]?[nextHoleNumber]
        let newHole: Hole
        if let pick = canonical {
            let coord = CLLocationCoordinate2D(latitude: pick.lat, longitude: pick.lon)
            newHole = Hole(id: holeId, number: nextHoleNumber, coordinate: coord, par: pick.par, teeId: round.selectedTeeId)
            ClientEventLogger.log("addNextHole.canonicalHydrated", detail: [
                "holeNumber": .integer(nextHoleNumber),
                "lat": .double(pick.lat),
                "lon": .double(pick.lon)
            ])
        } else {
            newHole = Hole(id: holeId, number: nextHoleNumber)
        }
        context.insert(newHole)
        round.holes.append(newHole)
        round.currentHoleNumber = nextHoleNumber
        // Every hole-index write logs battery. This path used to skip it, so a
        // course whose holes are all added in play (Blue Sky, 2026-09-07)
        // recorded no battery at all.
        ClientEventLogger.logBattery(hole: nextHoleNumber)
        try? context.save()
        ClientEventLogger.log("addNextHole.saved", detail: ["holeNumber": .integer(nextHoleNumber), "holeCount": .integer(round.holes.count)])
        SupabaseSync.shared.upsertRound(round)
        SupabaseSync.shared.upsertRoundHole(newHole, roundId: round.id)
        ClientEventLogger.log("addNextHole.upsertEnqueued")
        objectWillChange.send()
        ClientEventLogger.log("addNextHole.objectWillChangeSent")
    }

    func addHole(coordinate: CLLocationCoordinate2D, par: Int? = nil) {
        guard let round = currentRound, let context = context else { return }
        let nextHoleNumber = (round.holes.map(\.number).max() ?? 0) + 1
        let newHole = Hole(id: Hole.roundHoleId(roundId: round.id, number: nextHoleNumber),
                           number: nextHoleNumber, coordinate: coordinate, par: par)
        context.insert(newHole)
        round.holes.append(newHole)
        round.currentHoleNumber = nextHoleNumber
        ClientEventLogger.logBattery(hole: nextHoleNumber)
        try? context.save()
        SupabaseSync.shared.upsertRound(round)
        SupabaseSync.shared.upsertRoundHole(newHole, roundId: round.id)
        objectWillChange.send()
    }

    func updateHole(holeNumber: Int, newCoordinate: CLLocationCoordinate2D, par: Int? = nil) {
        ClientEventLogger.log("updateHole.start", detail: ["holeNumber": .integer(holeNumber), "par": par.map { .integer($0) } ?? .null])
        guard let round = currentRound, let context = context else {
            ClientEventLogger.log("updateHole.guardFailed.round")
            return
        }
        guard let hole = round.holes.first(where: { $0.number == holeNumber }) else {
            ClientEventLogger.log("updateHole.guardFailed.hole")
            return
        }
        hole.latitude = newCoordinate.latitude
        hole.longitude = newCoordinate.longitude
        if let par = par { hole.par = par }
        try? context.save()
        ClientEventLogger.log("updateHole.saved")
        SupabaseSync.shared.upsertRoundHole(hole, roundId: round.id)
        ClientEventLogger.log("updateHole.upsertEnqueued")
        objectWillChange.send()
        ClientEventLogger.log("updateHole.objectWillChangeSent")
    }

    func navigateToNextHole() {
        guard let round = currentRound, let next = round.hole(after: round.currentHoleNumber) else { return }
        setCurrentHole(number: next.number)
    }

    func navigateToPreviousHole() {
        guard let round = currentRound, let previous = round.hole(before: round.currentHoleNumber) else { return }
        setCurrentHole(number: previous.number)
    }
}
