import SwiftUI

// MARK: - Scorecard / Stroke State
//
// Score-relevant computed properties used by the live score readout and the
// undo gesture: which stroke was last real, which was first on the hole, and
// whether an undo is currently allowed.
extension ActiveRoundView {
    var canUndo: Bool {
        guard let hole = store.currentHole else { return false }

        // Can undo if current hole is finished
        if store.isHoleCompleted(hole.number) {
            return true
        }

        // Can undo if there are strokes on current hole
        let strokesForHole = store.currentRound?.strokes.filter { $0.holeNumber == hole.number } ?? []
        if !strokesForHole.isEmpty {
            return true
        }

        // Can undo if we just finished the previous hole (no strokes on current, previous is completed)
        // SwiftData relationship arrays are unordered — sort by number before
        // indexing, matching `WatchDataStore.currentHole`.
        if store.currentHoleIndex > 0,
           let round = store.currentRound {
            let sortedHoles = round.holes.sorted { $0.number < $1.number }
            guard store.currentHoleIndex - 1 < sortedHoles.count else { return false }
            let previousHoleNumber = sortedHoles[store.currentHoleIndex - 1].number
            return round.isHoleCompleted(previousHoleNumber)
        }

        return false
    }

    var lastRealStroke: Stroke? {
        guard let round = store.currentRound,
              let hole = store.currentHole else { return nil }

        let strokesForHole = round.strokes
            .filter { $0.holeNumber == hole.number && !$0.isPenalty }
            .sorted { $0.strokeNumber > $1.strokeNumber }

        return strokesForHole.first
    }

    var firstStroke: Stroke? {
        guard let round = store.currentRound else { return nil }

        // Determine hole number
        let holeNumber: Int
        if let hole = store.currentHole {
            holeNumber = hole.number
        } else {
            holeNumber = round.holes.count + 1
        }

        let strokesForHole = round.strokes
            .filter { $0.holeNumber == holeNumber }
            .sorted { $0.strokeNumber < $1.strokeNumber }

        return strokesForHole.first
    }
}
