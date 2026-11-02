import SwiftUI
import MapKit
import WatchKit

// MARK: - Map
//
// The hole map: markers, greens, the shot line and trail, other players, and
// the map shown before the round has a hole.
extension ActiveRoundView {

    @ViewBuilder
    func mapView(for hole: Hole) -> some View {
        standardMapView(for: hole)
    }

    @ViewBuilder
    func noHoleMapView() -> some View {
        MapReader { proxy in
            Map(position: $position, interactionModes: isInteractiveMapMode ? .all : []) {
                // Breadcrumb trail — small dots behind the user that fade
                // with age. Renders the most-recent slice of pathSamples.
                ForEach(Array(Array(locationManager.pathSamples.suffix(60)).enumerated()), id: \.element.id) { idx, bc in
                    let n = min(locationManager.pathSamples.count, 60)
                    let opacity = 0.08 + 0.55 * Double(idx) / Double(max(n - 1, 1))
                    Annotation("", coordinate: bc.coordinate) {
                        Circle()
                            .fill(Color(hex: store.myPlayerColor))
                            .frame(width: 4, height: 4)
                            .opacity(opacity)
                    }
                }

                // User location — tinted with the user's playgroup-assigned
                // color (defaults to blue when not in a playgroup).
                if let userLocation = locationManager.location {
                    Annotation("", coordinate: userLocation.coordinate) {
                        // Heading is no longer captured (we removed the
                        // tap-to-freeze feature and stopped subscribing to
                        // CMHeading altogether). Render the user as a
                        // direction-less dot in their playgroup color.
                        Circle()
                            .fill(Color(hex: store.myPlayerColor))
                            .frame(width: 7, height: 7)
                            .shadow(color: .white, radius: 2)
                            .shadow(color: .black.opacity(0.3), radius: 1)
                    }
                }

                // Stroke markers - show all strokes for current hole even if
                // no hole is defined. Penalty strokes are NOT rendered on the
                // map (the new penalty model is +1 to score with no map
                // marker — the orange "P: N" pill in the overlay is the
                // affordance).
                if let round = store.currentRound {
                    let nextHoleNumber = round.holes.count + 1
                    let strokesForHole = round.strokes
                        .filter { $0.holeNumber == nextHoleNumber && !$0.isPenalty }
                        .sorted { $0.strokeNumber < $1.strokeNumber }
                    LaunchRaysContent(rays: RoundTrail.launchRays(
                        ordered: strokesForHole, isPutt: isPuttStroke))
                    ForEach(Array(strokesForHole.enumerated()), id: \.element.id) { index, stroke in
                        Annotation("", coordinate: stroke.coordinate) {
                            ZStack {
                                Circle()
                                    .fill(.white)
                                    .frame(width: 20, height: 20)
                                    .opacity(0.85)
                                    .shadow(color: .black, radius: 2)

                                Text("\(stroke.strokeNumber)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.black)
                            }
                        }
                    }
                }

            }
            // Suppress all POI labels (golf course names, businesses, etc).
            // The course geometry (greens, centerline) is what matters; POI
            // text is just clutter on the watch.
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .modifier(HideMapControlsModifier(isInteractive: false))
        }
        .onAppear {
            restoreCalculatedMapPosition(force: true)
        }
    }

    func standardMapView(for hole: Hole) -> some View {
        // Caller (mainContent) now guards on `hole.hasLocation` before
        // invoking us, so `coordinate` is guaranteed non-nil here. The
        // force-unwrap stays — we want a hard signal if any future caller
        // forgets the pre-check.
        let holeCoord = hole.coordinate!
        // OSM polygon for the current hole's green. White outline only —
        // Apple Maps already renders the green tint underneath, so we
        // don't need our own fill. Source: `filteredGreenCandidates`
        // unifies OSM-derived greens (priority 1) and blob-detection
        // results (priority 2). Either one whose polygon contains the
        // hole's flag becomes the white outline overlay — same rendering
        // for both sources.
        let osmPolygon: [CLLocationCoordinate2D]? = {
            guard let courseId = store.currentRound?.courseId else { return nil }
            return store.filteredGreenCandidates(for: courseId)
                .first { $0.contains(holeCoord) }?
                .polygonCoordinates
        }()
        // OSM hole centerline — the tee→green linestring tagged `golf=hole`.
        // Only rendered when OSM coverage is complete (tier == .full). On
        // partial-tier courses (Sweetwater: 3 holes mapped, refs "1","1","2"
        // for an 18-hole course) the matched centerline is usually
        // misleading or wrong-hole, so we skip it entirely rather than
        // draw a yellow line through the wrong fairway.
        let osmCenterline: [CLLocationCoordinate2D]? = {
            guard let courseId = store.currentRound?.courseId,
                  let osm = store.osmCourseData(forCourseId: courseId),
                  osm.tier == .full else { return nil }
            let match = osm.holes.first { Int($0.ref ?? "") == hole.number }
            guard let pts = match?.centerline, pts.count >= 2 else { return nil }
            return pts.map(\.coordinate)
        }()
        // Putt count for the current hole — drives the centroid label.
        let puttCount: Int = {
            guard let round = store.currentRound else { return 0 }
            return round.strokes.filter { stroke in
                guard stroke.holeNumber == hole.number, !stroke.isPenalty else { return false }
                guard let club = store.availableClubs.first(where: { $0.id == stroke.clubId }) else { return false }
                return store.getTypeName(for: club) == "Putt"
            }.count
        }()
        // Polygon centroid (mean of vertices) — used to position the putt
        // count label inside the green when present.
        let polygonCentroid: CLLocationCoordinate2D? = {
            guard let pts = osmPolygon, !pts.isEmpty else { return nil }
            let lat = pts.map(\.latitude).reduce(0, +) / Double(pts.count)
            let lon = pts.map(\.longitude).reduce(0, +) / Double(pts.count)
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }()
        return MapReader { proxy in
            Map(position: $position, interactionModes: isInteractiveMapMode ? .all : []) {
                // OSM green polygon — white outline only, no fill (Apple
                // Maps' standard tile already shows the green underneath).
                if let pts = osmPolygon, pts.count >= 3 {
                    MapPolygon(coordinates: pts)
                        .foregroundStyle(.clear)
                        .stroke(.white, lineWidth: 1.5)
                }
                // OSM hole centerline — yellow dashed line tracing the
                // ideal tee→green path. Visually distinct from the white
                // player-trajectory connector that gets drawn from each
                // recorded stroke.
                if let line = osmCenterline {
                    MapPolyline(coordinates: line)
                        .stroke(
                            .yellow.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 3])
                        )
                }
                // Ghost round — the previous completed round at this
                // course, rendered UNDER the live content: dim dotted
                // grey walk path + dimmed grey stroke markers with
                // stroke numbers. Distinct from the yellow OSM
                // centerline (dashes) and the white live connector.
                if ghost.enabled {
                    if let ghostPath = ghost.pathByHole[hole.number], ghostPath.count >= 2 {
                        MapPolyline(coordinates: ghostPath)
                            .stroke(
                                .gray.opacity(0.5),
                                style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [2, 4])
                            )
                    }
                    // Same treatment as the live markers: putts filtered
                    // out, each dot labeled with the distance THAT shot
                    // went — to the next non-putt stroke, or (for the
                    // last one) to the first putt.
                    let ghostAll = ghost.strokesByHole[hole.number] ?? []
                    let ghostShots = ghostAll.filter { gs in
                        guard let cid = gs.clubId,
                              let club = store.availableClubs.first(where: { $0.id == cid }) else { return true }
                        return store.getTypeName(for: club) != "Putt"
                    }
                    let ghostFirstPutt = ghostAll.first { gs in
                        guard let cid = gs.clubId,
                              let club = store.availableClubs.first(where: { $0.id == cid }) else { return false }
                        return store.getTypeName(for: club) == "Putt"
                    }?.coordinate
                    ForEach(Array(ghostShots.enumerated()), id: \.element.id) { gi, gs in
                        Annotation("", coordinate: gs.coordinate) {
                            ZStack {
                                Circle()
                                    .fill(.gray.opacity(0.55))
                                    .frame(width: 5, height: 5)
                                let nextCoord: CLLocationCoordinate2D? = gi + 1 < ghostShots.count
                                    ? ghostShots[gi + 1].coordinate
                                    : ghostFirstPutt
                                if let next = nextCoord {
                                    let from = CLLocation(latitude: gs.coordinate.latitude, longitude: gs.coordinate.longitude)
                                    let to = CLLocation(latitude: next.latitude, longitude: next.longitude)
                                    Text("\(Int(from.distance(from: to) * 1.09361))")
                                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                                        .foregroundColor(.gray.opacity(0.85))
                                        .shadow(color: .black, radius: 1.5)
                                        .fixedSize()
                                        .offset(x: 12)
                                }
                            }
                        }
                    }
                }
                // "Putts: N" label rendered just above the green polygon.
                // Hidden at zero. Anchored at the polygon vertex
                // furthest from the user — in the rotated hole-at-top
                // view that's the visually-top edge of the polygon —
                // then offset upward in screen space so the label sits
                // outside the green rather than inside it. Screen-space
                // offset is rotation-independent so this stays above
                // the green regardless of map orientation.
                if puttCount > 0,
                   let pts = osmPolygon, !pts.isEmpty,
                   let userCoord = locationManager.location?.coordinate,
                   let topVertex = pts.max(by: { a, b in
                       let dA = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
                           .distance(from: CLLocation(latitude: a.latitude, longitude: a.longitude))
                       let dB = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
                           .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
                       return dA < dB
                   }) {
                    Annotation("", coordinate: topVertex) {
                        Text("Putts: \(puttCount)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .shadow(color: .black, radius: 2)
                            .offset(y: -14)
                    }
                } else if puttCount > 0, let center = polygonCentroid {
                    // Fallback when no user location yet — render at
                    // centroid with the screen-offset, accepting that
                    // this may overlap the green slightly.
                    Annotation("", coordinate: center) {
                        Text("Putts: \(puttCount)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .shadow(color: .black, radius: 2)
                    }
                }

                // Breadcrumb trail — small dots behind the user that fade
                // with age. Renders the most-recent slice of pathSamples.
                ForEach(Array(Array(locationManager.pathSamples.suffix(60)).enumerated()), id: \.element.id) { idx, bc in
                    let n = min(locationManager.pathSamples.count, 60)
                    let opacity = 0.08 + 0.55 * Double(idx) / Double(max(n - 1, 1))
                    Annotation("", coordinate: bc.coordinate) {
                        Circle()
                            .fill(Color(hex: store.myPlayerColor))
                            .frame(width: 4, height: 4)
                            .opacity(opacity)
                    }
                }

                // User location dot — direction-less. Heading capture is
                // gone (course-line will eventually drive intended direction);
                // CMHeading subscription is also off, so the previous arrow
                // had no real heading to point with.
                if let userLocation = locationManager.location {
                    Annotation("", coordinate: userLocation.coordinate) {
                        Circle()
                            .fill(Color(hex: store.myPlayerColor))
                            .frame(width: 7, height: 7)
                            .shadow(color: .white, radius: 2)
                            .shadow(color: .black.opacity(0.3), radius: 1)
                    }
                }

                // Stroke markers - show only in full view mode
                if isFullViewMode, let round = store.currentRound {
                    // Sort by strokeNumber, not the SwiftData @Relationship
                    // array's natural order — that order is undefined and
                    // shifts as new rows are inserted (especially via
                    // Realtime). Without an explicit sort, `.last` can return
                    // an earlier stroke, breaking the "locked-in yardage
                    // for completed shots, live yardage for the most recent
                    // shot" display logic.
                    //
                    // Putts are intentionally filtered out of the dot+yardage
                    // rendering — putts within the green get visualized via
                    // the centroid putt-count integer instead, since
                    // putt-to-putt yardage isn't meaningful and the dots
                    // would clutter the green. The "last non-putt stroke
                    // shows live distance to user" behavior naturally extends
                    // through the putting phase: while putting, the most
                    // recent non-putt stroke (e.g. the approach from 100yd
                    // out) keeps showing live distance from user position.
                    // Penalty strokes are excluded entirely from the map —
                    // the new penalty model is +1 to score with no marker.
                    let allStrokesForHole = round.strokes
                        .filter { $0.holeNumber == hole.number && !$0.isPenalty }
                        .sorted { $0.strokeNumber < $1.strokeNumber }
                    let strokesForHole = allStrokesForHole.filter { stroke in
                        guard let club = store.availableClubs.first(where: { $0.id == stroke.clubId }) else { return true }
                        return store.getTypeName(for: club) != "Putt"
                    }
                    // Connector polyline: each non-putt stroke in order, plus
                    // the first putt's location as the terminal endpoint
                    // (if any). The line visually traces "where the ball
                    // went" from tee through approach to the green; the
                    // putt-count integer takes over from there.
                    let firstPuttCoord: CLLocationCoordinate2D? = allStrokesForHole.first { stroke in
                        guard let club = store.availableClubs.first(where: { $0.id == stroke.clubId }) else { return false }
                        return store.getTypeName(for: club) == "Putt"
                    }?.coordinate
                    let connectorCoords: [CLLocationCoordinate2D] = {
                        var coords = strokesForHole.map(\.coordinate)
                        if let putt = firstPuttCoord { coords.append(putt) }
                        return coords
                    }()
                    if connectorCoords.count >= 2 {
                        MapPolyline(coordinates: connectorCoords)
                            .stroke(.white.opacity(0.9), lineWidth: 1.0)
                    }
                    // Each swing's derived launch bearing, beside the white
                    // line of where the ball actually went.
                    LaunchRaysContent(rays: RoundTrail.launchRays(
                        ordered: allStrokesForHole, isPutt: isPuttStroke))
                    ForEach(Array(strokesForHole.enumerated()), id: \.element.id) { index, stroke in
                        Annotation("", coordinate: stroke.coordinate) {
                            ZStack {
                                // Full view mode - small white circles
                                Circle()
                                    .fill(.white)
                                    .frame(width: 6, height: 6)
                                    .opacity(0.9)
                                    .shadow(color: .black, radius: 2)

                                // Show distance for all strokes in full view mode.
                                // For the LAST stroke (live distance to user),
                                // suppress until the user has moved out of the
                                // practice zone — within ignorePracticeRadius
                                // yards AND below the step gate counts as
                                // "still standing at the ball." Without this
                                // the readout flickers between 0 and small
                                // numbers while the user addresses the shot.
                                let distance: Int? = {
                                    if let lastStroke = strokesForHole.last, stroke.id == lastStroke.id {
                                        guard let userLoc = locationManager.location else { return nil }
                                        let strokeLoc = CLLocation(latitude: stroke.coordinate.latitude, longitude: stroke.coordinate.longitude)
                                        let yards = userLoc.distance(from: strokeLoc) * 1.09361
                                        let withinPracticeRadius = yards < swingDetector.ignorePracticeRadius
                                        let belowStepGate = swingDetector.stepsSinceLastDetectedSwing < swingDetector.stepGateThreshold
                                        if withinPracticeRadius && belowStepGate { return nil }
                                        return distanceToTarget(stroke.coordinate)
                                    } else if let nextIndex = strokesForHole.firstIndex(where: { $0.id == stroke.id }),
                                              nextIndex + 1 < strokesForHole.count {
                                        // Not last stroke - static distance to next stroke
                                        let nextStroke = strokesForHole[nextIndex + 1]
                                        let loc1 = CLLocation(latitude: stroke.coordinate.latitude, longitude: stroke.coordinate.longitude)
                                        let loc2 = CLLocation(latitude: nextStroke.coordinate.latitude, longitude: nextStroke.coordinate.longitude)
                                        return Int(loc1.distance(from: loc2) * 1.09361)
                                    }
                                    return nil
                                }()

                                // Yardage to LEFT of dot, elevation Δ to
                                // RIGHT. Both rendered as ZStack overlays so
                                // the dot itself stays anchored to the
                                // stroke's coordinate (HStack would shift
                                // the dot off-center as text widths varied).
                                if let dist = distance {
                                    Text("\(dist)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.white)
                                        .shadow(color: .black, radius: 2)
                                        .fixedSize()
                                        .offset(x: -18)
                                }
                                ElevationDeltaLabel(fontSize: 10,
                                                    shotFrom: stroke.coordinate,
                                                    shotTo: index + 1 < strokesForHole.count
                                                        ? strokesForHole[index + 1].coordinate : nil)
                                    .fixedSize()
                                    .offset(x: 18)
                            }
                        }
                    }
                }

                // Other players' strokes for the current hole, in their color
                // at 60% alpha. Lines connect each player's strokes in order.
                let myUid = WatchAuthSession.shared.currentUserId
                ForEach(playgroupChannel.members.filter { $0.userId != myUid }, id: \.userId) { member in
                    let strokes = playgroupChannel.otherStrokes[member.userId] ?? []
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
                                    .frame(width: 12, height: 12)
                                Text("\(stroke.strokeNumber)")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                }

                // Other players' live GPS dots from presence.
                ForEach(Array(playgroupChannel.presence.values.filter { $0.userId != myUid }), id: \.userId) { p in
                    let color = Color(hex: playgroupChannel.color(for: p.userId))
                    Annotation("", coordinate: p.coordinate) {
                        ZStack {
                            Circle().stroke(color, lineWidth: 2).frame(width: 14, height: 14)
                            Circle().fill(color).frame(width: 7, height: 7)
                        }
                    }
                }

                // Target markers
                ForEach(Array(targetCoordinatesBinding.wrappedValue.enumerated()), id: \.offset) { index, target in
                    Annotation("", coordinate: target) {
                        ZStack {
                            Image(systemName: "scope")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                                .shadow(color: .black, radius: 2)

                            if let distance = distanceToTarget(target) {
                                VStack {
                                    Spacer()
                                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                                        Text("\(distance)")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(.black)
                                        ElevationDeltaLabel(coordinate: target, fontSize: 9)
                                    }
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(Color.white.opacity(0.9))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    // Size to the text. The marker's 24pt frame
                                    // below otherwise squeezes "208" down to "…".
                                    .fixedSize()
                                    .offset(y: 18) // Position below the scope icon
                                }
                                .frame(height: 24)
                            }
                        }
                        .frame(width: 24, height: 24)
                    }
                }

            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .modifier(HideMapControlsModifier(isInteractive: isPlacingTarget))
            .allowsHitTesting(isPlacingTarget)
            .focusable(isPlacingTarget)
            .focused($isMapFocused)
            .onAppear {
                restoreCalculatedMapPosition(force: true)
            }
            .onTapGesture { screenLocation in
                guard let coordinate = proxy.convert(screenLocation, from: .local) else { return }

                if isPlacingTarget {
                    var coords = targetCoordinatesBinding.wrappedValue
                    let tappedLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

                    // Calculate deletion radius dynamically based on zoom level
                    // Convert a 30pt screen radius to meters at the current zoom
                    let tapPixelRadius: CGFloat = 30
                    let offsetPoint = CGPoint(x: screenLocation.x + tapPixelRadius, y: screenLocation.y)
                    let deletionRadius: Double
                    if let offsetCoord = proxy.convert(offsetPoint, from: .local) {
                        let offsetLocation = CLLocation(latitude: offsetCoord.latitude, longitude: offsetCoord.longitude)
                        deletionRadius = max(tappedLocation.distance(from: offsetLocation), 6.0)
                    } else {
                        deletionRadius = 6.0 // fallback
                    }
                    var deletedIndex: Int?

                    for (index, targetCoord) in coords.enumerated() {
                        let targetLocation = CLLocation(latitude: targetCoord.latitude, longitude: targetCoord.longitude)
                        let distance = tappedLocation.distance(from: targetLocation)

                        if distance <= deletionRadius {
                            deletedIndex = index
                            break
                        }
                    }

                    if let indexToDelete = deletedIndex {
                        ClientEventLogger.log("targetTap.delete", detail: ["index": .integer(indexToDelete), "before": .integer(coords.count)])
                        coords.remove(at: indexToDelete)
                        targetCoordinatesBinding.wrappedValue = coords
                        ClientEventLogger.log("targetTap.delete.afterBindingSet", detail: ["after": .integer(coords.count)])
                        WKInterfaceDevice.current().play(.click)
                    } else {
                        ClientEventLogger.log("targetTap.add", detail: ["before": .integer(coords.count)])
                        coords.append(coordinate)
                        targetCoordinatesBinding.wrappedValue = coords
                        WKInterfaceDevice.current().play(.success)
                    }
                }
            }
        }
    }
}
