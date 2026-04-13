import SwiftUI
import MapKit

// MARK: - Add-Penalty Mode
//
// UI for placing a penalty stroke somewhere on the map (drop zone / unplayable
// lie / OB). body dispatches into addPenaltyModeContent() when
// isAddingPenaltyStroke is true.
extension HolePlayView {
    @ViewBuilder
    func addPenaltyModeContent() -> some View {
        PenaltyStrokeMapView(
            position: $position,
            temporaryPosition: $temporaryPosition,
            currentHole: currentHole,
            currentRound: currentRound,
            userLocation: locationManager.location,
            heading: locationManager.heading,
            useStandardMap: useStandardMap
        )
        AddPenaltyStrokeOverlay(
            currentHole: currentHole,
            activeRound: activeRound,
            temporaryPosition: $temporaryPosition,
            isAddingPenaltyStroke: $isAddingPenaltyStroke,
            userLocation: locationManager.location,
            recordPenaltyStroke: recordPenaltyStroke,
            updateMapPosition: updateMapPosition
        )
    }
}
