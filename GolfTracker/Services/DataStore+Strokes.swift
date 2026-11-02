import Foundation
import CoreLocation

// Strokes and target markers within a round.
extension DataStore {

    func addStroke(to round: Round, holeNumber: Int, coordinate: CLLocationCoordinate2D, clubId: UUID, trajectoryHeading: Double? = nil) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }) else { return }

        let strokeNumber = Stroke.nextStrokeNumber(in: rounds[roundIndex], holeNumber: holeNumber)

        let stroke = Stroke(
            holeNumber: holeNumber,
            strokeNumber: strokeNumber,
            coordinate: coordinate,
            clubId: clubId,
            trajectoryHeading: trajectoryHeading,
            relAltMeters: LocationManager.shared.currentRelativeAltitudeMeters
        )
        rounds[roundIndex].strokes.append(stroke)
        saveRounds()

        // Mirror to Supabase (Realtime fans out to the other device)
        SupabaseSync.shared.upsertStroke(stroke, roundId: round.id)
        SupabaseSync.shared.upsertRound(rounds[roundIndex])
    }

    func updateStrokePosition(in round: Round, stroke: Stroke, newCoordinate: CLLocationCoordinate2D) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }),
              let strokeIndex = rounds[roundIndex].strokes.firstIndex(where: { $0.id == stroke.id }) else { return }

        rounds[roundIndex].strokes[strokeIndex].latitude = newCoordinate.latitude
        rounds[roundIndex].strokes[strokeIndex].longitude = newCoordinate.longitude

        saveRounds()
        SupabaseSync.shared.upsertStroke(rounds[roundIndex].strokes[strokeIndex], roundId: round.id)
    }

    func deleteStroke(in round: Round, stroke: Stroke) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }) else { return }

        // Remove the stroke
        rounds[roundIndex].strokes.removeAll { $0.id == stroke.id }

        // Renumber remaining strokes for the same hole
        let holeNumber = stroke.holeNumber
        for i in rounds[roundIndex].strokes.indices {
            if rounds[roundIndex].strokes[i].holeNumber == holeNumber {
                // Recalculate stroke number based on position in filtered array
                let strokesForHole = rounds[roundIndex].strokes.filter { $0.holeNumber == holeNumber }
                if let indexInHole = strokesForHole.firstIndex(where: { $0.id == rounds[roundIndex].strokes[i].id }) {
                    rounds[roundIndex].strokes[i].strokeNumber = indexInHole + 1
                }
            }
        }

        saveRounds()
        SupabaseSync.shared.deleteStroke(id: stroke.id)

        // Mirror to Supabase (Realtime fans out to the other device).
        // The surviving strokes on this hole were renumbered above.
        for s in rounds[roundIndex].strokes where s.holeNumber == holeNumber {
            SupabaseSync.shared.upsertStroke(s, roundId: round.id)
        }
        SupabaseSync.shared.upsertRound(rounds[roundIndex])
    }

    func addPenaltyStroke(to round: Round, holeNumber: Int, coordinate: CLLocationCoordinate2D, clubId: UUID) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }) else { return }

        let strokesForHole = rounds[roundIndex].strokes.filter { $0.holeNumber == holeNumber }
        let strokeNumber = strokesForHole.count + 1

        let stroke = Stroke(
            holeNumber: holeNumber,
            strokeNumber: strokeNumber,
            coordinate: coordinate,
            clubId: clubId,
            isPenalty: true,
            relAltMeters: LocationManager.shared.currentRelativeAltitudeMeters
        )
        rounds[roundIndex].strokes.append(stroke)
        saveRounds()

        // Mirror to Supabase (Realtime fans out to the other device)
        SupabaseSync.shared.upsertStroke(stroke, roundId: round.id)
        SupabaseSync.shared.upsertRound(rounds[roundIndex])
    }

    func renumberStroke(in round: Round, stroke: Stroke, newNumber: Int) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }),
              let strokeIndex = rounds[roundIndex].strokes.firstIndex(where: { $0.id == stroke.id }) else { return }

        let oldNumber = rounds[roundIndex].strokes[strokeIndex].strokeNumber
        let holeNumber = stroke.holeNumber

        // If the number didn't change, do nothing
        guard oldNumber != newNumber else { return }

        // Update the stroke number
        rounds[roundIndex].strokes[strokeIndex].strokeNumber = newNumber

        // Adjust other stroke numbers for the same hole
        for i in rounds[roundIndex].strokes.indices {
            if rounds[roundIndex].strokes[i].holeNumber == holeNumber &&
               rounds[roundIndex].strokes[i].id != stroke.id {
                let currentNumber = rounds[roundIndex].strokes[i].strokeNumber

                if oldNumber < newNumber {
                    // Moving stroke later: decrease numbers in between
                    if currentNumber > oldNumber && currentNumber <= newNumber {
                        rounds[roundIndex].strokes[i].strokeNumber -= 1
                    }
                } else {
                    // Moving stroke earlier: increase numbers in between
                    if currentNumber >= newNumber && currentNumber < oldNumber {
                        rounds[roundIndex].strokes[i].strokeNumber += 1
                    }
                }
            }
        }

        saveRounds()
        for s in rounds[roundIndex].strokes where s.holeNumber == holeNumber {
            SupabaseSync.shared.upsertStroke(s, roundId: round.id)
        }
    }

    /// Replace the target markers for one hole of a round. Owns both the
    /// local mutation and the Supabase mirror (including deletes for
    /// removed targets, which the blanket round upsert never covered).
    func setTargets(for round: Round, holeNumber: Int, coordinates: [CLLocationCoordinate2D]) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }) else { return }

        let removed = rounds[roundIndex].targets.filter { $0.holeNumber == holeNumber }
        rounds[roundIndex].targets.removeAll { $0.holeNumber == holeNumber }

        let newTargets = coordinates.map { Target(holeNumber: holeNumber, coordinate: $0) }
        rounds[roundIndex].targets.append(contentsOf: newTargets)
        saveRounds()

        for target in removed {
            SupabaseSync.shared.deleteTarget(id: target.id)
        }
        for target in newTargets {
            SupabaseSync.shared.upsertTarget(target, roundId: round.id)
        }
    }
}
