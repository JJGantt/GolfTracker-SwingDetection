import SwiftUI
import MapKit

struct HoleMapView: View {
    let hole: Hole
    let currentRound: Round?
    let userLocation: CLLocation?
    let heading: CLLocationDirection?
    let useStandardMap: Bool
    @Binding var position: MapCameraPosition
    @Binding var targetCoordinates: [CLLocationCoordinate2D]
    @Binding var isPlacingTarget: Bool
    @Binding var isDeleting: Bool
    let distanceToTarget: (CLLocationCoordinate2D) -> Int?

    let onHoleTap: () -> Void
    let onStrokeTap: (Int) -> Void

    private var isHoleCompleted: Bool {
        currentRound?.isHoleCompleted(hole.number) ?? false
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                // Show current hole marker (green if completed, yellow if not)
                Annotation("", coordinate: hole.coordinate) {
                    Image(systemName: "flag.fill")
                        .foregroundColor(isHoleCompleted ? .green : .yellow)
                        .font(.title)
                        .onTapGesture {
                            onHoleTap()
                        }
                }

                // Show strokes for current hole
                if let round = currentRound {
                    let strokesForHole = round.strokes.filter { $0.holeNumber == hole.number }
                    ForEach(Array(strokesForHole.enumerated()), id: \.element.id) { index, stroke in
                        // Show stroke position
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
                                .onTapGesture {
                                    onStrokeTap(index)
                                }
                            } else {
                                GolfBallMarker(strokeNumber: stroke.strokeNumber)
                                    .onTapGesture {
                                        onStrokeTap(index)
                                    }
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

                // Target markers
                ForEach(Array(targetCoordinates.enumerated()), id: \.offset) { index, target in
                    Annotation("", coordinate: target) {
                        ZStack {
                            Image(systemName: "scope")
                                .font(.system(size: 32))
                                .foregroundColor(.white)
                                .shadow(color: .black, radius: 2)

                            if let distance = distanceToTarget(target) {
                                VStack {
                                    Spacer()
                                    Text("\(distance)")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.black)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color.white.opacity(0.9))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .offset(y: 24) // Position below the scope icon
                                }
                                .frame(height: 32)
                            }
                        }
                        .frame(width: 32, height: 32)
                        .onTapGesture {
                            if isPlacingTarget {
                                // Remove the target immediately
                                targetCoordinates.remove(at: index)
                                // Set flag to block the map tap that will fire immediately after
                                isDeleting = true
                                // Reset the flag on the next run loop so future taps work normally
                                DispatchQueue.main.async {
                                    isDeleting = false
                                }
                            }
                        }
                    }
                }
            }
            .mapStyle(useStandardMap ? .standard : .hybrid)
            .mapControls {
                MapUserLocationButton()
                MapScaleView()
            }
            .onTapGesture { screenLocation in
                guard isPlacingTarget else { return }

                // If we just deleted a target, skip placing a new one
                if isDeleting {
                    return
                }

                guard let coordinate = proxy.convert(screenLocation, from: .local) else { return }

                // Add new target
                targetCoordinates.append(coordinate)
            }
        }
    }
}
