import SwiftUI
import MapKit

// MARK: - Add Hole Views

struct AddHoleMapView: View {
    @Binding var position: MapCameraPosition
    @Binding var temporaryHolePosition: CLLocationCoordinate2D?
    @Binding var hasUserInteracted: Bool
    let userLocation: CLLocation?
    let heading: CLLocationDirection?
    let useStandardMap: Bool

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                // Show user location
                if let userLocation = userLocation {
                    Annotation("", coordinate: userLocation.coordinate) {
                        UserLocationMarker(heading: heading)
                    }
                }

                // Show temporary hole position
                if let holePos = temporaryHolePosition {
                    Annotation("", coordinate: holePos) {
                        Image(systemName: "flag.fill")
                            .foregroundColor(.yellow)
                            .font(.title)
                    }
                }
            }
            .mapStyle(useStandardMap ? .standard : .hybrid)
            .onMapCameraChange { context in
                // Mark as interacted when user pans the map
                hasUserInteracted = true
            }
            .onTapGesture { screenCoord in
                hasUserInteracted = true
                if let coordinate = proxy.convert(screenCoord, from: .local) {
                    temporaryHolePosition = coordinate
                }
            }
        }
    }
}

struct AddHoleOverlay: View {
    let holeCount: Int
    @Binding var temporaryHolePosition: CLLocationCoordinate2D?
    @Binding var isAddingHole: Bool
    let saveTemporaryHole: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Instructions at top
            VStack(spacing: 8) {
                Text("Add Hole \(holeCount + 1)")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Tap the map to place the flag")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding()
            .padding(.top, 50)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)

            Spacer()

            // Par buttons and Cancel at bottom
            VStack(spacing: 12) {
                if temporaryHolePosition != nil {
                    HStack(spacing: 12) {
                        // Par 3 button
                        Button(action: { saveTemporaryHole(3) }) {
                            VStack(spacing: 4) {
                                Text("3")
                                    .font(.title)
                                    .fontWeight(.bold)
                                Text("Par")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)

                        // Par 4 button
                        Button(action: { saveTemporaryHole(4) }) {
                            VStack(spacing: 4) {
                                Text("4")
                                    .font(.title)
                                    .fontWeight(.bold)
                                Text("Par")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)

                        // Par 5 button
                        Button(action: { saveTemporaryHole(5) }) {
                            VStack(spacing: 4) {
                                Text("5")
                                    .font(.title)
                                    .fontWeight(.bold)
                                Text("Par")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                }

                Button(action: {
                    isAddingHole = false
                    temporaryHolePosition = nil
                }) {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .padding(.bottom, 20)
            .background(.ultraThinMaterial)
        }
    }
}

// MARK: - Manual Placement Views (Shared by Move Hole and Add Tee)

struct ManualPlacementMapView: View {
    @Binding var position: MapCameraPosition
    @Binding var temporaryPosition: CLLocationCoordinate2D?
    let currentHole: Hole?
    let userLocation: CLLocation?
    let heading: CLLocationDirection?
    let useStandardMap: Bool
    let isAddingTeeManually: Bool

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                // Show current hole
                if let hole = currentHole {
                    Annotation("", coordinate: hole.coordinate) {
                        Image(systemName: "flag.fill")
                            .foregroundColor(.yellow)
                            .font(.title)
                    }
                }

                // Show temporary position marker
                if let tempPos = temporaryPosition {
                    Annotation("", coordinate: tempPos) {
                        ZStack {
                            Circle()
                                .fill(isAddingTeeManually ? .green : .orange)
                                .frame(width: 40, height: 40)
                            if isAddingTeeManually {
                                Circle()
                                    .stroke(.black, lineWidth: 2)
                                    .frame(width: 40, height: 40)
                                Text("T")
                                    .font(.headline)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                            } else {
                                Image(systemName: "flag.fill")
                                    .foregroundColor(.yellow)
                                    .font(.title)
                            }
                        }
                    }
                }

                // Show user location
                if let userLocation = userLocation {
                    Annotation("", coordinate: userLocation.coordinate) {
                        UserLocationMarker(heading: heading)
                    }
                }
            }
            .mapStyle(useStandardMap ? .standard : .hybrid)
            .onTapGesture { screenCoord in
                if let coordinate = proxy.convert(screenCoord, from: .local) {
                    temporaryPosition = coordinate
                }
            }
        }
    }
}

struct MoveHoleManuallyOverlay: View {
    let currentHole: Hole?
    @Binding var temporaryPosition: CLLocationCoordinate2D?
    @Binding var isMovingHoleManually: Bool
    @Binding var savedMapRegion: MKCoordinateRegion?
    let userLocation: CLLocation?
    let store: DataStore
    let currentCourse: Course
    let restoreSavedMapRegion: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Move Hole \(currentHole?.number ?? 0)")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Tap the map to place the hole")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding()
            .padding(.top, 50)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)

            Spacer()

            VStack(spacing: 12) {
                // Par buttons - only show when hole has been moved
                if temporaryPosition != nil {
                    HStack(spacing: 12) {
                        // Par 3 button
                        Button(action: { saveHoleLocation(par: 3) }) {
                            VStack(spacing: 4) {
                                Text("3")
                                    .font(.title)
                                    .fontWeight(.bold)
                                Text("Par")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white, lineWidth: currentHole?.par == 3 ? 3 : 0)
                        )

                        // Par 4 button
                        Button(action: { saveHoleLocation(par: 4) }) {
                            VStack(spacing: 4) {
                                Text("4")
                                    .font(.title)
                                    .fontWeight(.bold)
                                Text("Par")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white, lineWidth: currentHole?.par == 4 ? 3 : 0)
                        )

                        // Par 5 button
                        Button(action: { saveHoleLocation(par: 5) }) {
                            VStack(spacing: 4) {
                                Text("5")
                                    .font(.title)
                                    .fontWeight(.bold)
                                Text("Par")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white, lineWidth: currentHole?.par == 5 ? 3 : 0)
                        )
                    }
                }

                HStack(spacing: 8) {
                    Button(action: {
                        guard let location = userLocation else { return }
                        temporaryPosition = location.coordinate
                    }) {
                        Image(systemName: "location.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    .disabled(userLocation == nil)

                    Button(action: {
                        restoreSavedMapRegion()
                        isMovingHoleManually = false
                        temporaryPosition = nil
                        savedMapRegion = nil
                    }) {
                        Text("Cancel")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .padding(.bottom, 20)
            .background(.ultraThinMaterial)
        }
    }

    private func saveHoleLocation(par: Int) {
        guard let hole = currentHole,
              let coordinate = temporaryPosition else { return }
        store.updateHole(hole, in: currentCourse, newCoordinate: coordinate, par: par)
        restoreSavedMapRegion()
        isMovingHoleManually = false
        temporaryPosition = nil
        savedMapRegion = nil
    }
}

// MARK: - Stroke Movement Views

struct StrokeMovementMapView: View {
    @Binding var position: MapCameraPosition
    @Binding var temporaryPosition: CLLocationCoordinate2D?
    let currentHole: Hole?
    let currentRound: Round?
    let strokeToMove: Stroke?
    let userLocation: CLLocation?
    let heading: CLLocationDirection?
    let useStandardMap: Bool

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                // Show current hole
                if let hole = currentHole {
                    Annotation("", coordinate: hole.coordinate) {
                        Image(systemName: "flag.fill")
                            .foregroundColor(.yellow)
                            .font(.title)
                    }

                    // Show other strokes for current hole (not the one being moved)
                    if let round = currentRound {
                        let strokesForHole = round.strokes.filter {
                            $0.holeNumber == hole.number && $0.id != strokeToMove?.id
                        }
                        ForEach(strokesForHole) { stroke in
                            Annotation("", coordinate: stroke.coordinate) {
                                GolfBallMarker(strokeNumber: stroke.strokeNumber)
                            }
                        }
                    }
                }

                // Show temporary position marker for stroke being moved
                if let tempPos = temporaryPosition {
                    Annotation("", coordinate: tempPos) {
                        ZStack {
                            Circle()
                                .fill(.orange)
                                .frame(width: 40, height: 40)
                            if let stroke = strokeToMove {
                                Text("\(stroke.strokeNumber)")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                }

                // Show user location
                if let userLocation = userLocation {
                    Annotation("", coordinate: userLocation.coordinate) {
                        UserLocationMarker(heading: heading)
                    }
                }
            }
            .mapStyle(useStandardMap ? .standard : .hybrid)
            .onTapGesture { screenCoord in
                if let coordinate = proxy.convert(screenCoord, from: .local) {
                    temporaryPosition = coordinate
                }
            }
        }
    }
}

struct MoveStrokeOverlay: View {
    let strokeToMove: Stroke?
    let activeRound: Round?
    @Binding var temporaryPosition: CLLocationCoordinate2D?
    @Binding var isMovingStroke: Bool
    @Binding var strokeToMoveBinding: Stroke?
    @Binding var savedMapRegion: MKCoordinateRegion?
    let userLocation: CLLocation?
    let store: DataStore
    let restoreSavedMapRegion: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Move Stroke \(strokeToMove?.strokeNumber ?? 0)")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Tap the map to reposition the stroke")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding()
            .padding(.top, 50)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)

            Spacer()

            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    if temporaryPosition != nil {
                        Button(action: {
                            guard let stroke = strokeToMove,
                                  let round = activeRound,
                                  let coordinate = temporaryPosition else { return }
                            store.updateStrokePosition(in: round, stroke: stroke, newCoordinate: coordinate)
                            restoreSavedMapRegion()
                            isMovingStroke = false
                            strokeToMoveBinding = nil
                            temporaryPosition = nil
                            savedMapRegion = nil
                        }) {
                            Label("Save", systemImage: "checkmark.circle.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }

                    Button(action: {
                        guard let location = userLocation else { return }
                        temporaryPosition = location.coordinate
                    }) {
                        Image(systemName: "location.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    .disabled(userLocation == nil)

                    Button(action: {
                        restoreSavedMapRegion()
                        isMovingStroke = false
                        strokeToMoveBinding = nil
                        temporaryPosition = nil
                        savedMapRegion = nil
                    }) {
                        Text("Cancel")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .padding(.bottom, 20)
            .background(.ultraThinMaterial)
        }
    }
}

// MARK: - Penalty Stroke Views

struct PenaltyStrokeMapView: View {
    @Binding var position: MapCameraPosition
    @Binding var temporaryPosition: CLLocationCoordinate2D?
    let currentHole: Hole?
    let currentRound: Round?
    let userLocation: CLLocation?
    let heading: CLLocationDirection?
    let useStandardMap: Bool

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                // Show current hole
                if let hole = currentHole {
                    Annotation("", coordinate: hole.coordinate) {
                        Image(systemName: "flag.fill")
                            .foregroundColor(.yellow)
                            .font(.title)
                    }

                    // Show other strokes for current hole
                    if let round = currentRound {
                        let strokesForHole = round.strokes.filter { $0.holeNumber == hole.number }
                        ForEach(strokesForHole) { stroke in
                            Annotation("", coordinate: stroke.coordinate) {
                                if stroke.isPenalty {
                                    // Orange ball for penalty strokes
                                    ZStack {
                                        Circle()
                                            .fill(.orange)
                                            .frame(width: 25, height: 25)
                                        Text("\(stroke.strokeNumber)")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundColor(.white)
                                    }
                                } else {
                                    GolfBallMarker(strokeNumber: stroke.strokeNumber)
                                }
                            }
                        }
                    }
                }

                // Show temporary position marker for penalty stroke
                if let tempPos = temporaryPosition {
                    Annotation("", coordinate: tempPos) {
                        ZStack {
                            Circle()
                                .fill(.orange.opacity(0.8))
                                .frame(width: 35, height: 35)
                            if let round = currentRound, let hole = currentHole {
                                let strokeCount = round.strokes.filter { $0.holeNumber == hole.number }.count
                                Text("\(strokeCount + 1)")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                }

                // Show user location
                if let userLocation = userLocation {
                    Annotation("", coordinate: userLocation.coordinate) {
                        UserLocationMarker(heading: heading)
                    }
                }
            }
            .mapStyle(useStandardMap ? .standard : .hybrid)
            .onTapGesture { screenCoord in
                if let coordinate = proxy.convert(screenCoord, from: .local) {
                    temporaryPosition = coordinate
                }
            }
        }
    }
}

struct AddPenaltyStrokeOverlay: View {
    let currentHole: Hole?
    let activeRound: Round?
    @Binding var temporaryPosition: CLLocationCoordinate2D?
    @Binding var isAddingPenaltyStroke: Bool
    let userLocation: CLLocation?
    let recordPenaltyStroke: () -> Void
    let updateMapPosition: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Add Penalty Stroke")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Tap the map to place the penalty stroke")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding()
            .padding(.top, 100)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)

            Spacer()

            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    if temporaryPosition != nil {
                        Button(action: recordPenaltyStroke) {
                            Label("Save", systemImage: "checkmark.circle.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }

                    Button(action: {
                        guard let location = userLocation else { return }
                        temporaryPosition = location.coordinate
                    }) {
                        Image(systemName: "location.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    .disabled(userLocation == nil)

                    Button(action: {
                        updateMapPosition()
                        isAddingPenaltyStroke = false
                        temporaryPosition = nil
                    }) {
                        Text("Cancel")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .padding(.bottom, 20)
            .background(.ultraThinMaterial)
        }
    }
}
