import SwiftUI
import MapKit

// MARK: - Add-Hole Mode
//
// UI for placing a new hole at the current GPS (or manually tapping on the
// map, or picking a detected green blob). The body's if-else dispatch
// calls addHoleModeContent() when isAddingHole is true.
extension HolePlayView {
    @ViewBuilder
    func addHoleModeContent() -> some View {
        let candidates = (currentRound?.holeDetectionEnabled == true)
            ? store.filteredHoleDetectionBlobs(for: currentCourse.id)
            : [HoleDetectionBlob]()
        AddHoleMapView(
            position: $position,
            temporaryHolePosition: $temporaryHolePosition,
            hasUserInteracted: $hasUserInteractedWithAddHoleMap,
            isManualPlacement: $isAddHoleManualMode,
            selectedGreenBlobId: $addHoleSelectedBlobId,
            userLocation: locationManager.location,
            heading: locationManager.heading,
            greenCandidates: candidates
        )
        AddHoleOverlay(
            holeCount: currentCourse.holes.count,
            hasGreenCandidates: !candidates.isEmpty,
            userLocation: locationManager.location,
            temporaryHolePosition: $temporaryHolePosition,
            selectedGreenBlobId: $addHoleSelectedBlobId,
            isManualPlacement: $isAddHoleManualMode,
            isAddingHole: $isAddingHole,
            saveTemporaryHole: saveTemporaryHole
        )
    }
}
