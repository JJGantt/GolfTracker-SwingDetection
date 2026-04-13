import SwiftUI
import MapKit

// MARK: - Move-Hole Mode
//
// UI for relocating the current hole by dragging on a manual-placement map.
// Entered by tapping the existing hole marker. body dispatches into
// moveHoleModeContent() when isMovingHoleManually is true.
extension HolePlayView {
    @ViewBuilder
    func moveHoleModeContent() -> some View {
        ManualPlacementMapView(
            position: $position,
            temporaryPosition: $temporaryPosition,
            currentHole: currentHole,
            userLocation: locationManager.location,
            heading: locationManager.heading,
            useStandardMap: useStandardMap,
            isAddingTeeManually: false
        )
        MoveHoleManuallyOverlay(
            currentHole: currentHole,
            temporaryPosition: $temporaryPosition,
            isMovingHoleManually: $isMovingHoleManually,
            savedMapRegion: $savedMapRegion,
            userLocation: locationManager.location,
            store: store,
            currentCourse: currentCourse,
            restoreSavedMapRegion: restoreSavedMapRegion
        )
    }
}
