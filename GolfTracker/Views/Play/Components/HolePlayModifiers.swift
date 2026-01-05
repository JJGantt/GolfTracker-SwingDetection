import SwiftUI
import MapKit

// MARK: - View Modifiers for HolePlayView

struct NavigationModifier: ViewModifier {
    @Binding var showingCourseEditor: Bool
    let store: DataStore
    let currentCourse: Course

    func body(content: Content) -> some View {
        content
            .navigationDestination(isPresented: $showingCourseEditor) {
                CourseEditorView(store: store, course: currentCourse)
            }
    }
}

struct HoleEditingModifier: ViewModifier {
    @Binding var showingMoveHoleConfirmation: Bool
    let currentHole: Hole?
    let locationManager: LocationManager
    @Binding var temporaryPosition: CLLocationCoordinate2D?
    @Binding var isMovingHoleManually: Bool
    let store: DataStore
    let currentCourse: Course
    let moveCurrentHoleToUserLocation: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Move Hole Position", isPresented: $showingMoveHoleConfirmation) {
                Button("Move to Current Location") {
                    moveCurrentHoleToUserLocation()
                }
                .disabled(locationManager.location == nil)

                Button("Move Manually") {
                    temporaryPosition = currentHole?.coordinate
                    isMovingHoleManually = true
                }

                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Choose how to move hole \(currentHole?.number ?? 0)")
            }
    }
}


struct StrokeDetailsModifier: ViewModifier {
    @Binding var showingStrokeDetails: Bool
    let activeRound: Round?
    let strokesForCurrentHole: [Stroke]
    @Binding var selectedStrokeIndex: Int
    @Binding var isMovingStroke: Bool
    @Binding var strokeToMove: Stroke?
    @Binding var temporaryPosition: CLLocationCoordinate2D?
    @Binding var position: MapCameraPosition
    @Binding var savedMapRegion: MKCoordinateRegion?
    let store: DataStore

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingStrokeDetails) {
                if let round = activeRound {
                    StrokeDetailsView(
                        store: store,
                        round: round,
                        strokes: strokesForCurrentHole,
                        selectedStrokeIndex: $selectedStrokeIndex,
                        isMovingStroke: $isMovingStroke,
                        strokeToMove: $strokeToMove,
                        temporaryPosition: $temporaryPosition,
                        position: $position,
                        savedMapRegion: $savedMapRegion
                    )
                }
            }
    }
}
