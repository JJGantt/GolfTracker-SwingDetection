import Foundation
import CoreLocation
import SwiftData

// Strokes and target markers in the current round.
extension WatchDataStore {

    // MARK: - Stroke Management

    @discardableResult
    func addStroke(clubId: UUID, trajectoryHeading: Double? = nil, coordinate: CLLocationCoordinate2D? = nil, isPenalty: Bool = false) -> UUID? {
        guard let round = currentRound, let context = context else { return nil }
        guard let strokeCoordinate = coordinate ?? LocationManager.shared.location?.coordinate else { return nil }

        // Tee shot is away — the distance heuristic can take over until the
        // approach brings us back inside gpsModerateYards. No-op after the
        // first stroke on the hole.
        LocationManager.shared.releaseTeeHoldIfNeeded()

        let holeNumber: Int
        if let hole = currentHole {
            holeNumber = hole.number
        } else {
            holeNumber = round.holes.count + 1
        }

        let strokeNumber = Stroke.nextStrokeNumber(in: round, holeNumber: holeNumber)

        let stroke = Stroke(
            holeNumber: holeNumber,
            strokeNumber: strokeNumber,
            coordinate: strokeCoordinate,
            clubId: clubId,
            isPenalty: isPenalty,
            trajectoryHeading: trajectoryHeading,
            relAltMeters: LocationManager.shared.currentRelativeAltitudeMeters
        )
        context.insert(stroke)
        round.strokes.append(stroke)
        round.lastActivityAt = Date()
        try? context.save()

        // Push to Supabase via the shared sync layer.
        SupabaseSync.shared.upsertStroke(stroke, roundId: round.id)
        SupabaseSync.shared.upsertRound(round)
        objectWillChange.send()
        return stroke.id
    }

    /// Convenience: adds a penalty stroke at the current GPS. Penalties no
    /// longer get placed on the map (the placement-mode UI was removed); each
    /// call is just "+1 to the score." Picks any available club for the
    /// `clubId` slot since `Stroke.clubId` is non-optional and the value is
    /// unused for penalties.
    @discardableResult
    func addPenaltyStroke() -> UUID? {
        guard let club = availableClubs.first else { return nil }
        return addStroke(clubId: club.id, isPenalty: true)
    }

    /// Penalty stroke count for a hole. Drives the orange "P: N" readout.
    func penaltyCount(for hole: Hole) -> Int {
        currentRound?.strokes.filter { $0.holeNumber == hole.number && $0.isPenalty }.count ?? 0
    }

    func updateStrokeClub(strokeId: UUID, clubId: UUID) {
        guard let round = currentRound, let context = context else { return }
        guard let stroke = round.strokes.first(where: { $0.id == strokeId }) else { return }
        stroke.clubId = clubId
        try? context.save()
        SupabaseSync.shared.upsertStroke(stroke, roundId: round.id)
        objectWillChange.send()
    }

    func deleteLastStroke() {
        guard let round = currentRound, let context = context else { return }

        let hole = currentHole
        let strokesForHole = hole.map { h in round.strokes.filter { $0.holeNumber == h.number } } ?? []

        // If current hole is finished, reopen it (don't delete strokes or move back).
        if let hole = hole, round.isHoleCompleted(hole.number) {
            reopenHole(holeNumber: hole.number)
            return
        }

        // If there are strokes on current hole, delete the last one.
        if let lastStroke = strokesForHole.sorted(by: { $0.strokeNumber < $1.strokeNumber }).last {
            let strokeId = lastStroke.id
            context.delete(lastStroke)
            try? context.save()
            SupabaseSync.shared.deleteStroke(id: strokeId)
            objectWillChange.send()
        } else if let previous = round.hole(before: round.currentHoleNumber),
                  round.isHoleCompleted(previous.number) {
            // No strokes here and the previous hole was just finished.
            reopenHole(holeNumber: previous.number)
            setCurrentHole(number: previous.number)
        }
    }

    func replaceTargets(forHoleNumber holeNumber: Int?, with coordinates: [CLLocationCoordinate2D]) {
        ClientEventLogger.log("replaceTargets.start", detail: [
            "holeNumber": holeNumber.map { .integer($0) } ?? .null,
            "newCount": .integer(coordinates.count)
        ])
        guard let holeNumber = holeNumber,
              let round = currentRound,
              let context = context else {
            ClientEventLogger.log("replaceTargets.guardFailed")
            return
        }
        let toDelete = round.targets.filter { $0.holeNumber == holeNumber }
        ClientEventLogger.log("replaceTargets.toDelete", detail: ["count": .integer(toDelete.count)])
        for target in toDelete {
            context.delete(target)
            SupabaseSync.shared.deleteTarget(id: target.id)
        }
        for coord in coordinates {
            let t = Target(holeNumber: holeNumber, coordinate: coord)
            context.insert(t)
            round.targets.append(t)
            SupabaseSync.shared.upsertTarget(t, roundId: round.id)
        }
        try? context.save()
        ClientEventLogger.log("replaceTargets.saved", detail: ["roundTargetsCount": .integer(round.targets.count)])
        objectWillChange.send()
    }

    func strokeCount(for hole: Hole) -> Int {
        currentRound?.strokes.filter { $0.holeNumber == hole.number }.count ?? 0
    }

    /// Putts taken on this hole — strokes whose club resolves to type
    /// name "Putt". Same definition `AutoAdvanceMonitor` uses for its
    /// putt-since-arrival gate, kept consistent so the UI count and the
    /// auto-advance trigger never disagree.
    func puttCount(for hole: Hole) -> Int {
        guard let strokes = currentRound?.strokes else { return 0 }
        return strokes.reduce(0) { count, stroke in
            guard stroke.holeNumber == hole.number else { return count }
            guard let club = availableClubs.first(where: { $0.id == stroke.clubId }) else { return count }
            return getTypeName(for: club) == "Putt" ? count + 1 : count
        }
    }
}
