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

    /// Live multiplayer state for the current playgroup. When the user
    /// isn't in a playgroup these collections are empty and nothing renders.
    @ObservedObject private var playgroup = PlaygroupChannel.shared

    /// Per-hole breadcrumb cache pulled from `round_altitude_readings`.
    /// Drives the fading-dot trail. Loaded by `HolePlayView` on appear
    /// + hole change; this view just reads.
    @ObservedObject private var roundPath = RoundPathCache.shared

    /// Ghost-round overlay data (previous completed round at this
    /// course). Loaded by `HolePlayView` alongside the breadcrumb
    /// refresh; this view just reads.
    @ObservedObject private var ghost = GhostRoundStore.shared

    private var isHoleCompleted: Bool {
        currentRound?.isHoleCompleted(hole.number) ?? false
    }

    /// Source-agnostic green polygon for the current hole — same lookup
    /// the watch uses (`filteredGreenCandidates` returns OSM polygons
    /// when present, blob-detected polygons otherwise).
    private var currentGreenPolygon: [CLLocationCoordinate2D]? {
        guard let courseId = currentRound?.courseId,
              let holeCoord = hole.coordinate else { return nil }
        return DataStore.shared.filteredGreenCandidates(for: courseId)
            .first { $0.contains(holeCoord) }?
            .polygonCoordinates
    }

    /// OSM hole centerline. Only rendered when full-tier OSM coverage —
    /// partial-tier (mismapped refs) gives the wrong line.
    private var currentCenterline: [CLLocationCoordinate2D]? {
        guard let courseId = currentRound?.courseId,
              let osm = DataStore.shared.osmCourseData(forCourseId: courseId),
              osm.tier == .full else { return nil }
        let match = osm.holes.first { Int($0.ref ?? "") == hole.number }
        guard let pts = match?.centerline, pts.count >= 2 else { return nil }
        return pts.map(\.coordinate)
    }

    /// Putts on this hole — strokes whose club resolves to type "Putt".
    /// Drives the "Putts: N" label above the green.
    private var puttCount: Int {
        guard let round = currentRound else { return 0 }
        return round.strokes.reduce(0) { count, stroke in
            guard stroke.holeNumber == hole.number, !stroke.isPenalty else { return count }
            guard let club = DataStore.shared.availableClubs.first(where: { $0.id == stroke.clubId }) else { return count }
            return DataStore.shared.getTypeName(for: club) == "Putt" ? count + 1 : count
        }
    }

    /// User color = their playgroup color via PlaygroupChannel, or the
    /// default solo color (palette[0]) when not in a playgroup.
    private var userColor: Color {
        let uid = AuthManager.shared.currentUserId ?? ""
        return Color(hex: PlaygroupChannel.shared.color(for: uid))
    }

    /// Yards to display next to a stroke marker. Last stroke shows
    /// live distance to the user; prior strokes show static distance
    /// to the next stroke. Mirrors the watch's logic in
    /// `ActiveRoundView.swift` stroke annotation block.
    private func strokeYardage(strokesForHole: [Stroke], index: Int) -> Int? {
        guard !strokesForHole.isEmpty, index < strokesForHole.count else { return nil }
        let stroke = strokesForHole[index]
        let strokeLoc = CLLocation(latitude: stroke.coordinate.latitude, longitude: stroke.coordinate.longitude)
        if index == strokesForHole.count - 1 {
            guard let user = userLocation else { return nil }
            return Int(user.distance(from: strokeLoc) * 1.09361)
        } else {
            let next = strokesForHole[index + 1]
            let nextLoc = CLLocation(latitude: next.coordinate.latitude, longitude: next.coordinate.longitude)
            return Int(strokeLoc.distance(from: nextLoc) * 1.09361)
        }
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                // Green polygon outline — white stroke, no fill (Apple Maps
                // tile already shows the green underneath). Same shape as
                // watch ActiveRoundView.
                if let pts = currentGreenPolygon, pts.count >= 3 {
                    MapPolygon(coordinates: pts)
                        .foregroundStyle(.clear)
                        .stroke(.white, lineWidth: 1.5)
                }

                // OSM hole centerline — yellow dashed line tracing the
                // ideal tee→green path. Matches watch styling.
                if let line = currentCenterline {
                    MapPolyline(coordinates: line)
                        .stroke(
                            .yellow.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 3])
                        )
                }

                // "Putts: N" label above the green polygon. Anchored at
                // the polygon vertex furthest from the user (lands at
                // visual top in the rotated hole-at-top view), with a
                // screen-space upward offset so it sits outside the
                // green outline. Hidden at zero. Centroid fallback when
                // no user location.
                if puttCount > 0,
                   let pts = currentGreenPolygon, !pts.isEmpty {
                    let anchorCoord: CLLocationCoordinate2D = {
                        if let userCoord = userLocation?.coordinate,
                           let furthest = pts.max(by: { a, b in
                               let dA = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
                                   .distance(from: CLLocation(latitude: a.latitude, longitude: a.longitude))
                               let dB = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
                                   .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
                               return dA < dB
                           }) {
                            return furthest
                        }
                        // Centroid fallback
                        let lat = pts.map(\.latitude).reduce(0, +) / Double(pts.count)
                        let lon = pts.map(\.longitude).reduce(0, +) / Double(pts.count)
                        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    }()
                    Annotation("", coordinate: anchorCoord) {
                        Text("Putts: \(puttCount)")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .shadow(color: .black, radius: 2)
                            .offset(y: -16)
                    }
                }

                // Ghost round — previous completed round at this course:
                // dim dotted grey path + dimmed grey numbered stroke
                // markers, rendered under the live content. Same
                // treatment as the watch map.
                if ghost.enabled {
                    if let ghostPath = ghost.pathByHole[hole.number], ghostPath.count >= 2 {
                        MapPolyline(coordinates: ghostPath)
                            .stroke(
                                .gray.opacity(0.5),
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 5])
                            )
                    }
                    // Same treatment as the live markers: putts filtered
                    // out, each dot labeled with the distance THAT shot
                    // went — to the next non-putt stroke, or (for the
                    // last one) to the first putt.
                    let ghostAll = ghost.strokesByHole[hole.number] ?? []
                    let ghostShots = ghostAll.filter { gs in
                        guard let cid = gs.clubId,
                              let club = DataStore.shared.availableClubs.first(where: { $0.id == cid }) else { return true }
                        return DataStore.shared.getTypeName(for: club) != "Putt"
                    }
                    let ghostFirstPutt = ghostAll.first { gs in
                        guard let cid = gs.clubId,
                              let club = DataStore.shared.availableClubs.first(where: { $0.id == cid }) else { return false }
                        return DataStore.shared.getTypeName(for: club) == "Putt"
                    }?.coordinate
                    ForEach(Array(ghostShots.enumerated()), id: \.element.id) { gi, gs in
                        Annotation("", coordinate: gs.coordinate) {
                            ZStack {
                                Circle()
                                    .fill(.gray.opacity(0.55))
                                    .frame(width: 8, height: 8)
                                let nextCoord: CLLocationCoordinate2D? = gi + 1 < ghostShots.count
                                    ? ghostShots[gi + 1].coordinate
                                    : ghostFirstPutt
                                if let next = nextCoord {
                                    let from = CLLocation(latitude: gs.coordinate.latitude, longitude: gs.coordinate.longitude)
                                    let to = CLLocation(latitude: next.latitude, longitude: next.longitude)
                                    Text("\(Int(from.distance(from: to) * 1.09361))")
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundColor(.gray.opacity(0.9))
                                        .shadow(color: .black, radius: 1.5)
                                        .fixedSize()
                                        .offset(x: 16)
                                }
                            }
                        }
                    }
                }

                // Breadcrumb trail — fading dots from the per-hole
                // path samples uploaded by whichever device captured
                // them (typically the watch). Most recent ~60 samples
                // with a brightness gradient — older samples fade.
                // Same styling as the watch's breadcrumb.
                if let round = currentRound {
                    let breadcrumbs = roundPath.samples(forRoundId: round.id, holeNumber: hole.number)
                    let recent = Array(breadcrumbs.suffix(60))
                    let n = recent.count
                    let userColorBC = userColor
                    ForEach(Array(recent.enumerated()), id: \.element.id) { idx, bc in
                        let opacity = 0.08 + 0.55 * Double(idx) / Double(max(n - 1, 1))
                        Annotation("", coordinate: bc.coordinate) {
                            Circle()
                                .fill(userColorBC)
                                .frame(width: 6, height: 6)
                                .opacity(opacity)
                        }
                    }
                }

                // Show current hole marker (green if completed, yellow if not)
                if let holeCoord = hole.coordinate {
                    Annotation("", coordinate: holeCoord) {
                        Image(systemName: "flag.fill")
                            .foregroundColor(isHoleCompleted ? .green : .yellow)
                            .font(.title)
                            .onTapGesture {
                                onHoleTap()
                            }
                    }
                }

                // Show strokes for current hole. Yardage label to LEFT
                // of the dot, ElevationDeltaLabel to RIGHT. Both rendered
                // as ZStack overlays with offsets so the dot stays
                // anchored to the stroke's coordinate (HStack would shift
                // the anchor as text widths varied). Mirrors watch.
                if let round = currentRound {
                    let strokesForHole = round.strokes.filter { $0.holeNumber == hole.number }
                    // Line through your own shots, matching the watch: each
                    // non-putt stroke in order, ending at the first putt (the
                    // putt count takes over on the green). The phone drew the
                    // markers but no line between them — only other players'
                    // shots were connected.
                    let shotLine: [CLLocationCoordinate2D] = {
                        let ordered = strokesForHole
                            .filter { !$0.isPenalty }
                            .sorted { $0.strokeNumber < $1.strokeNumber }
                        func isPutt(_ s: Stroke) -> Bool {
                            guard let club = DataStore.shared.availableClubs.first(where: { $0.id == s.clubId }) else { return false }
                            return DataStore.shared.getTypeName(for: club) == "Putt"
                        }
                        var coords = ordered.filter { !isPutt($0) }.map(\.coordinate)
                        if let firstPutt = ordered.first(where: isPutt) { coords.append(firstPutt.coordinate) }
                        return coords
                    }()
                    if shotLine.count >= 2 {
                        MapPolyline(coordinates: shotLine)
                            .stroke(.white.opacity(0.9), lineWidth: 1.5)
                    }
                    ForEach(Array(strokesForHole.enumerated()), id: \.element.id) { index, stroke in
                        Annotation("", coordinate: stroke.coordinate) {
                            ZStack {
                                if stroke.isPenalty {
                                    Circle()
                                        .fill(.orange)
                                        .frame(width: 25, height: 25)
                                    Text("\(stroke.strokeNumber)")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(.white)
                                } else {
                                    GolfBallMarker(strokeNumber: stroke.strokeNumber)
                                }

                                // Yardage label — last stroke = live distance to
                                // user, prior strokes = static distance to next
                                // stroke. Same logic as watch.
                                let yardage: Int? = strokeYardage(strokesForHole: strokesForHole, index: index)
                                if let yds = yardage {
                                    Text("\(yds)")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.white)
                                        .shadow(color: .black, radius: 2)
                                        .fixedSize()
                                        .offset(x: -32)
                                }
                                ElevationDeltaLabel(fontSize: 14,
                                                    shotFrom: stroke.coordinate,
                                                    shotTo: index + 1 < strokesForHole.count
                                                        ? strokesForHole[index + 1].coordinate : nil)
                                    .fixedSize()
                                    .offset(x: 32)
                            }
                            .onTapGesture { onStrokeTap(index) }
                        }
                    }
                }

                // Show user location
                if let userLocation = userLocation {
                    Annotation("", coordinate: userLocation.coordinate) {
                        UserLocationMarker(heading: heading, color: userColor)
                    }
                }

                // Other players' strokes for the current hole, in their color
                // at 60% alpha. Lines connect each player's strokes in order.
                ForEach(playgroup.members.filter { $0.userId != AuthManager.shared.currentUserId }, id: \.userId) { member in
                    let strokes = playgroup.otherStrokes[member.userId] ?? []
                    let color = Color(hex: member.color ?? PlaygroupService.playerPalette[0])
                    if strokes.count >= 2 {
                        MapPolyline(coordinates: strokes.map { $0.coordinate })
                            .stroke(color.opacity(0.45), lineWidth: 2)
                    }
                    ForEach(strokes) { stroke in
                        Annotation("", coordinate: stroke.coordinate) {
                            ZStack {
                                Circle()
                                    .fill(color.opacity(0.6))
                                    .frame(width: 18, height: 18)
                                Text("\(stroke.strokeNumber)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                }

                // Other players' live GPS dots (presence). Solid color circle
                // ring + smaller filled center, so they're distinguishable from
                // stroke markers.
                ForEach(Array(playgroup.presence.values.filter { $0.userId != AuthManager.shared.currentUserId }), id: \.userId) { p in
                    let color = Color(hex: playgroup.color(for: p.userId))
                    Annotation("", coordinate: p.coordinate) {
                        ZStack {
                            Circle().stroke(color, lineWidth: 2).frame(width: 16, height: 16)
                            Circle().fill(color).frame(width: 8, height: 8)
                        }
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
                                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                                        Text("\(distance)")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundColor(.black)
                                        ElevationDeltaLabel(coordinate: target, fontSize: 12)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.white.opacity(0.9))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    // Size to the text. The marker's 32pt frame
                                    // below otherwise squeezes "118" down to "1…".
                                    .fixedSize()
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
