import SwiftUI
import CoreLocation

struct HoleOverlayControls: View {
    let hole: Hole
    let strokeCount: Int
    let formattedDistance: String
    let errorMessage: String?
    let currentHoleIndex: Int
    let totalHoles: Int
    let strokes: [Stroke]
    let userLocation: CLLocation?
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onAddHole: () -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Distance display section
            VStack(spacing: 8) {
                Text(formattedDistance)
                    .font(.system(size: 60, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding()
            .padding(.top, 80)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)

            Spacer()

            // Hole info panel
            HStack(spacing: 20) {
                VStack(spacing: 4) {
                    Text("Hole")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(hole.number)")
                        .font(.title2)
                        .fontWeight(.bold)
                }

                Divider()
                    .frame(height: 40)

                VStack(spacing: 4) {
                    Text("Par")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let par = hole.par {
                        Text("\(par)")
                            .font(.title2)
                            .fontWeight(.bold)
                    } else {
                        Text("--")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }
                }

                Divider()
                    .frame(height: 40)

                VStack(spacing: 4) {
                    Text("Strokes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(strokeCount)")
                        .font(.title2)
                        .fontWeight(.bold)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)

            // Navigation controls
            HStack(spacing: 20) {
                Button(action: onPrevious) {
                    Label("Previous", systemImage: "chevron.left")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(currentHoleIndex == 0)

                if currentHoleIndex >= totalHoles - 1 {
                    Button(action: onAddHole) {
                        Label("Add", systemImage: "plus")
                            .labelStyle(.titleAndIcon)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(action: onNext) {
                        Label("Next", systemImage: "chevron.right")
                            .labelStyle(.titleAndIcon)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .padding(.bottom, 20)
            .background(.ultraThinMaterial)
            }

            // Stroke data table overlay (below distance banner)
            if !strokes.isEmpty {
                VStack {
                    HStack {
                        StrokeDataTable(strokes: strokes, userLocation: userLocation, hole: hole)
                        Spacer()
                    }
                    .padding(.leading, 16)
                    .padding(.top, 190)
                    Spacer()
                }
            }
        }
    }
}

struct StrokeDataTable: View {
    let strokes: [Stroke]
    let userLocation: CLLocation?
    let hole: Hole

    private func distanceForStroke(at index: Int) -> String {
        // Distance is from this stroke to the next stroke (where the ball landed)
        guard index + 1 < strokes.count else {
            return "---"
        }

        let stroke = strokes[index]
        let nextStroke = strokes[index + 1]

        let strokeLocation = CLLocation(latitude: stroke.latitude, longitude: stroke.longitude)
        let nextLocation = CLLocation(latitude: nextStroke.latitude, longitude: nextStroke.longitude)
        let distanceInMeters = strokeLocation.distance(from: nextLocation)
        let yards = Int(distanceInMeters * 1.09361)
        return "\(yards)"
    }

    private func angleForStroke(at index: Int) -> String {
        // Need the next stroke in the array to calculate where this shot landed
        guard index + 1 < strokes.count else {
            return "---"
        }

        let stroke = strokes[index]
        let nextStroke = strokes[index + 1]

        guard let trajectoryHeading = stroke.trajectoryHeading else { return "---" }

        // Calculate bearing from stroke to where it actually landed (next stroke position)
        let actualBearing = calculateBearing(from: stroke.coordinate, to: nextStroke.coordinate)

        // Calculate offset from intended trajectory to actual result
        let offset = (actualBearing - trajectoryHeading + 360).truncatingRemainder(dividingBy: 360)
        let normalizedOffset = offset > 180 ? offset - 360 : offset

        return String(format: "%.0f°", normalizedOffset)
    }

    private func calculateBearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180.0
        let lon1 = from.longitude * .pi / 180.0
        let lat2 = to.latitude * .pi / 180.0
        let lon2 = to.longitude * .pi / 180.0

        let dLon = lon2 - lon1

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let bearing = atan2(y, x)

        let bearingDegrees = bearing * 180.0 / .pi
        return (bearingDegrees + 360.0).truncatingRemainder(dividingBy: 360.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(strokes.enumerated()), id: \.element.id) { index, stroke in
                HStack(spacing: 6) {
                    Text("\(index + 1)")
                        .font(.system(size: 13))
                        .foregroundColor(stroke.isPenalty ? .orange : .black)
                        .frame(width: 14, alignment: .center)
                    Text(stroke.isPenalty ? "---" : distanceForStroke(at: index))
                        .font(.system(size: 13))
                        .foregroundColor(.black)
                        .frame(width: 30, alignment: .trailing)
                    Text(stroke.isPenalty ? "---" : angleForStroke(at: index))
                        .font(.system(size: 13))
                        .foregroundColor(.black)
                        .frame(width: 30, alignment: .trailing)
                    Spacer()
                        .frame(width: 4)
                    Text(stroke.isPenalty ? "---" : stroke.club.rawValue)
                        .font(.system(size: 13))
                        .foregroundColor(.black)
                        .frame(width: 35, alignment: .leading)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.7))
                .cornerRadius(4)
            }
        }
    }
}
