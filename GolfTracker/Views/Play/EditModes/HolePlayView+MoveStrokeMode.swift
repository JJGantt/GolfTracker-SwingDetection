import SwiftUI
import MapKit

// MARK: - Move-Stroke Mode
//
// UI for repositioning an existing stroke on the map. Entered by tapping a
// stroke marker and selecting "move." body dispatches into
// moveStrokeModeContent() when isMovingStroke is true.
extension HolePlayView {
    @ViewBuilder
    func moveStrokeModeContent() -> some View {
        StrokeMovementMapView(
            position: $position,
            temporaryPosition: $temporaryPosition,
            currentHole: currentHole,
            currentRound: currentRound,
            strokeToMove: strokeToMove,
            userLocation: locationManager.location,
            heading: locationManager.heading,
            useStandardMap: useStandardMap
        )
        MoveStrokeOverlay(
            strokeToMove: strokeToMove,
            activeRound: activeRound,
            temporaryPosition: $temporaryPosition,
            isMovingStroke: $isMovingStroke,
            strokeToMoveBinding: $strokeToMove,
            savedMapRegion: $savedMapRegion,
            userLocation: locationManager.location,
            store: store,
            restoreSavedMapRegion: restoreSavedMapRegion
        )
    }
}
