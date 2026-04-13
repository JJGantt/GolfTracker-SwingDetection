import SwiftUI

// MARK: - Club Prediction & Selection
//
// Prediction-logic helpers, auto-add overlay club commit, and swing-detector
// club-name sync (which also drives GPS power modes when the putter is picked).
extension ActiveRoundView {
    func putterClubIndex() -> Int? {
        clubs.indices.first { index in
            guard let clubType = store.clubTypes.first(where: { $0.id == clubs[index].clubTypeId }) else { return false }
            return clubType.name == "Putt"
        }
    }

    /// Commits the overlay's crown-selected club to the auto-added stroke.
    /// Called on dismiss (X) and at the start of any new auto-add (covers "dismissed by new stroke").
    func commitOverlayClub() {
        guard let strokeId = autoAddedStrokeId, let club = overlaySelectedClub else { return }
        store.updateStrokeClub(strokeId: strokeId, clubId: club.id)
    }

    func applyClubPrediction() {
        guard store.clubPredictionMode != .off,
              let distance = distanceToHole else { return }
        if let predictedIndex = ClubPredictionManager.shared.predictClubIndex(
            forDistance: distance,
            clubs: clubs,
            clubTypes: store.clubTypes,
            mode: store.clubPredictionMode,
            customAverages: store.customClubAverages,
            disabledClubs: store.disabledPredictionClubs
        ) {
            isAutoSelectingClub = true
            selectedClubIndex = Double(predictedIndex)
            updateSwingDetectorClub()
            isAutoSelectingClub = false
        }
    }

    func updateSwingDetectorClub() {
        guard let club = selectedClub else { return }
        let newTypeName = store.getTypeName(for: club)
        swingDetector.selectedClubTypeName = newTypeName

        if newTypeName == "Putt" {
            locationManager.setGPSPowerMode(.off)
        } else if locationManager.gpsPowerMode == .off {
            // Switching away from putter — restore GPS based on distance
            updateGPSForDistance()
        }
    }

    func handleSelectedClubIndexChange() {
        if !isAutoSelectingClub && store.clubPredictionMode != .off {
            manualClubOverride = true
        }

        updateSwingDetectorClub()

        withAnimation(.easeInOut(duration: 0.15)) {
            isCrownScrolling = true
        }

        crownScrollTimer?.invalidate()
        crownScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                isCrownScrolling = false
            }
        }
    }
}
