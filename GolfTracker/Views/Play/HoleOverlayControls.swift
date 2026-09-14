import SwiftUI
import CoreLocation

struct HoleOverlayControls: View {
    let hole: Hole
    let strokeCount: Int
    let formattedDistance: String
    let errorMessage: String?
    let hasPreviousHole: Bool
    let hasNextHole: Bool
    let strokes: [Stroke]
    let userLocation: CLLocation?
    let store: DataStore
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onAddHole: () -> Void

    /// Whole yards from the user to the flag — numeric twin of
    /// `formattedDistance`, feeds the plays-like calculation.
    private var distanceYardsToHole: Int? {
        guard let user = userLocation, let coord = hole.coordinate else { return nil }
        let target = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        return Int(user.distance(from: target) * 1.09361)
    }

    /// Club the plays-like readout assumes. The iOS play screen has no
    /// club selection (that lives on the watch), so pick the
    /// self-consistent best match across the user's club types — the
    /// club whose average distance matches the plays-like number that
    /// club itself would produce. See `PlaysLike.bestCandidate`.
    private var playsLikeClubTypeName: String? {
        guard let d = distanceYardsToHole else { return nil }
        let candidates: [(item: String, typeName: String, averageYards: Int)] = store.clubTypes
            .filter { $0.name != "Putt" }
            .compactMap { t in
                guard let avg = t.averageDistance else { return nil }
                return (t.name, t.name, avg)
            }
        return PlaysLike.bestCandidate(distanceYards: d,
                                       deltaMeters: ElevationReadout.shared.deltaToGreenMeters,
                                       candidates: candidates)
    }

    /// True when the user's GPS sits inside the current hole's green
    /// polygon. Source-agnostic — same `filteredGreenCandidates` lookup
    /// used elsewhere. Drives the on-green color flip on the big
    /// yardage readout (white → bright green).
    private var isUserOnCurrentGreen: Bool {
        guard let userCoord = userLocation?.coordinate,
              let holeCoord = hole.coordinate,
              let courseId = store.rounds.first(where: { $0.endedAt == nil })?.courseId
        else { return false }
        let blob = store.filteredGreenCandidates(for: courseId)
            .first { $0.contains(holeCoord) }
        guard let blob, !blob.polygon.isEmpty else { return false }
        return blob.contains(userCoord)
    }

    @Environment(\.playControlsBottomInset) private var bottomInset

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Distance display section
            VStack(spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    Text(formattedDistance)
                        .font(.system(size: 60, weight: .bold, design: .rounded))
                        .foregroundColor(isUserOnCurrentGreen
                            ? Color(red: 0.4, green: 0.95, blue: 0.4)
                            : .white)
                    PlaysLikeStack(distanceYards: distanceYardsToHole,
                                   clubTypeName: playsLikeClubTypeName,
                                   playsLikeFontSize: 28,
                                   deltaFontSize: 22)
                }

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
                .disabled(!hasPreviousHole)

                if !hasNextHole {
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
            .padding(.bottom, bottomInset)
            .background(.ultraThinMaterial)
            }

            // Stroke data table overlay (below distance banner)
            if !strokes.isEmpty {
                VStack {
                    HStack {
                        StrokeDataTable(strokes: strokes, userLocation: userLocation, hole: hole, store: store)
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
    let store: DataStore

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
            ForEach(Array(strokes.enumerated()), id: \.element.id) { item in
                let index = item.offset
                let stroke = item.element

                HStack(spacing: 6) {
                    Text("\(index + 1)")
                        .font(.system(size: 13))
                        .foregroundColor(stroke.isPenalty ? .orange : .black)
                        .frame(width: 14, alignment: .center)

                    let distance = stroke.isPenalty ? "---" : distanceForStroke(at: index)
                    Text(distance)
                        .font(.system(size: 13))
                        .foregroundColor(.black)
                        .frame(width: 30, alignment: .trailing)

                    let angle = stroke.isPenalty ? "---" : angleForStroke(at: index)
                    Text(angle)
                        .font(.system(size: 13))
                        .foregroundColor(.black)
                        .frame(width: 30, alignment: .trailing)

                    Spacer()
                        .frame(width: 4)

                    let clubName = stroke.isPenalty ? "---" : (store.getClub(byId: stroke.clubId).flatMap { store.getClubType(byId: $0.clubTypeId) }?.name ?? "?")
                    Text(clubName)
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
