import SwiftUI
import MapKit

/// Unified hole placement view for adding a new hole and editing an existing one.
///
/// - `isEditing: false` — add mode: flag appears only after tap; par buttons appear after first tap;
///   saving does NOT dismiss (parent transitions automatically when hole gains a location).
/// - `isEditing: true`  — edit mode: existing flag shown immediately; current par gets a white ring
///   indicator; saving calls `dismiss()`.
struct HolePlacementView: View {
    @ObservedObject var store: WatchDataStore
    @ObservedObject var locationManager: LocationManager
    let hole: Hole
    let isEditing: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var position: MapCameraPosition = .automatic
    @State private var temporaryHolePosition: CLLocationCoordinate2D?
    @State private var selectedGreenBlobId: UUID?
    @State private var isManualPlacement = false
    /// The map camera's rotation, so the facing wedge stays true to the
    /// ground if the map is ever turned off north-up.
    @State private var mapHeading: CLLocationDirection = 0
    private let greenSnapDistanceMeters: CLLocationDistance = 50

    private var greenCandidates: [HoleDetectionBlob] {
        guard store.currentRound?.holeDetectionEnabled == true else { return [] }
        return store.filteredGreenCandidates(for: store.currentRound?.courseId)
    }

    /// Pre-filtered list passed to the MapContent ForEach. Splitting the
    /// guard out of the loop keeps MapContentBuilder happy.
    private var renderableBlobs: [HoleDetectionBlob] {
        greenCandidates.filter { $0.polygonCoordinates.count >= 3 }
    }

    /// API-derived par for this hole at the round's selected tee. When
    /// non-nil, the par picker is skipped — tapping a position auto-saves
    /// with this par.
    private var knownPar: Int? {
        store.teeHolePars[hole.number]
    }

    var body: some View {
        let trail = RoundTrail(round: store.currentRound,
                               pathSamples: locationManager.pathSamples,
                               isPutt: isPutt)
        ZStack {
            // Map layer
            MapReader { proxy in
                Map(position: $position) {
                    // The round so far — walked path, each hole's shots,
                    // where each flag went, each swing's launch bearing.
                    // Drawn first so the live markers sit on top. Which way
                    // the round has been travelling is most of what tells
                    // you which green is next.
                    RoundTrailContent(trail: trail, pathColor: Color(hex: store.myPlayerColor))

                    // Breadcrumb trail — small dots behind the user that
                    // fade with age. Renders the most-recent slice of
                    // pathSamples; the full array (no upper bound) is
                    // captured for upload to round_altitude_readings.
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

                    // User location dot with a wedge for the way the watch
                    // faces. Only this screen runs the compass (see
                    // `LocationManager.beginCompass`); the round-play map's
                    // dot stays direction-less. Tinted with playgroup color
                    // to match the main round-play map.
                    if let userLocation = locationManager.location {
                        Annotation("", coordinate: userLocation.coordinate, anchor: .center) {
                            FacingDot(compass: locationManager.compass,
                                      color: Color(hex: store.myPlayerColor),
                                      diameter: isEditing ? 7 : 9,
                                      mapHeading: mapHeading)
                        }
                    }

                    // Flag marker — behaviour differs by mode
                    if selectedGreenBlobId == nil {
                        if isEditing {
                            // Edit mode: show existing hole coordinate until user moves it
                            if let holePosition = temporaryHolePosition ?? hole.coordinate {
                                Annotation("", coordinate: holePosition) {
                                    Image(systemName: "flag.fill")
                                        .foregroundColor(.yellow)
                                        .font(.system(size: 24))
                                        .shadow(color: .black, radius: 2)
                                }
                            }
                        } else {
                            // Add mode: only show after user taps
                            if let holePos = temporaryHolePosition {
                                Annotation("", coordinate: holePos) {
                                    Image(systemName: "flag.fill")
                                        .foregroundColor(.yellow)
                                        .font(.system(size: 24))
                                        .shadow(color: .black, radius: 2)
                                }
                            }
                        }
                    }

                    // Suggested greens from phone-side blob detection.
                    // Filter the empty/degenerate polygons out BEFORE the
                    // ForEach — SwiftUI's MapContentBuilder has been
                    // unreliable with `if` guards inside MapContent ForEach,
                    // which is why this used to render zero outlines even
                    // when greenCandidates was populated.
                    ForEach(renderableBlobs) { blob in
                        MapPolyline(coordinates: blob.polygonCoordinates + [blob.polygonCoordinates[0]])
                            .stroke(
                                blob.id == selectedGreenBlobId ? Color.yellow : Color.white,
                                lineWidth: blob.id == selectedGreenBlobId ? 4 : 1.5
                            )
                    }
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                .onMapCameraChange { context in
                    mapHeading = context.camera.heading
                }
                .modifier(HideMapControlsModifier(isInteractive: true))
                .onTapGesture { screenCoord in
                    if let coordinate = proxy.convert(screenCoord, from: .local) {
                        if isManualPlacement || greenCandidates.isEmpty {
                            temporaryHolePosition = coordinate
                            selectedGreenBlobId = nil
                        } else {
                            let nearestBlob = greenCandidates
                                .min { $0.centroidDistanceMeters(to: coordinate) < $1.centroidDistanceMeters(to: coordinate) }
                            if let blob = nearestBlob,
                               blob.centroidDistanceMeters(to: coordinate) <= greenSnapDistanceMeters {
                                temporaryHolePosition = blob.centroidCoordinate
                                selectedGreenBlobId = blob.id
                            }
                        }
                        WKInterfaceDevice.current().play(.click)
                        // If the API gave us the par for this hole and
                        // we're in add mode, skip the par picker entirely
                        // and save immediately with the known par. Edit
                        // mode keeps the picker so the user can override.
                        if !isEditing, let par = knownPar, temporaryHolePosition != nil {
                            save(par: par)
                        }
                    }
                }
            }
            .ignoresSafeArea()

            // Top overlay: title + optional manual-placement toggle + distance label
            VStack(spacing: 2) {
                ZStack(alignment: .leading) {
                    Text(isEditing ? "Edit Hole \(hole.number)" : "Hole \(hole.number)")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.gray.opacity(0.6))
                        .clipShape(Capsule())
                        .frame(maxWidth: .infinity)

                    if !greenCandidates.isEmpty {
                        Button {
                            isManualPlacement.toggle()
                            if !isManualPlacement {
                                temporaryHolePosition = nil
                                selectedGreenBlobId = nil
                            }
                        } label: {
                            Image(systemName: isManualPlacement ? "mappin.and.ellipse" : "hand.tap")
                                .font(.system(size: 12))
                                .foregroundColor(isManualPlacement ? .orange : .white)
                                .padding(5)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.top, 8)

                if let holePos = temporaryHolePosition,
                   let userLoc = locationManager.location {
                    let yards = Int(userLoc.distance(
                        from: CLLocation(latitude: holePos.latitude, longitude: holePos.longitude)
                    ) * 1.09361)
                    Text("\(yards) yds")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .ignoresSafeArea()

            // Par buttons — appear once a position has been tapped, but
            // ONLY when the API doesn't give us the par for this hole. In
            // add mode with a known par, the tap handler above auto-saves
            // and dismisses without ever showing the picker.
            if temporaryHolePosition != nil && !(knownPar != nil && !isEditing) {
                VStack {
                    Spacer()

                    HStack(spacing: 8) {
                        ForEach([3, 4, 5], id: \.self) { par in
                            Button(action: { save(par: par) }) {
                                ZStack {
                                    Circle()
                                        .fill(Color.green.opacity(0.95))
                                        .frame(width: 50, height: 50)
                                        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)

                                    // Edit mode: ring highlights the existing par
                                    if isEditing && hole.par == par {
                                        Circle()
                                            .stroke(Color.white, lineWidth: 3)
                                            .frame(width: 50, height: 50)
                                    }

                                    Text("\(par)")
                                        .font(.system(size: 24, weight: .bold))
                                        .foregroundColor(.white)
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 16)
                }
                .ignoresSafeArea()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .onAppear {
            ClientEventLogger.log("HolePlacementView.onAppear", detail: ["holeNumber": .integer(hole.number), "isEditing": .bool(isEditing)])
            locationManager.requestPermission()
            locationManager.startTracking()
            locationManager.beginCompass()

            let spanInMeters: CLLocationDistance = 320.0 // ~350 yards
            let spanDegrees = spanInMeters / 111000.0

            if isEditing {
                // Center on existing hole coordinate, fall back to user location
                if let center = hole.coordinate ?? locationManager.location?.coordinate {
                    position = .region(MKCoordinateRegion(
                        center: center,
                        span: MKCoordinateSpan(latitudeDelta: spanDegrees, longitudeDelta: spanDegrees)
                    ))
                }
            } else {
                // Center on user location
                if let userLocation = locationManager.location {
                    position = .region(MKCoordinateRegion(
                        center: userLocation.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: spanDegrees, longitudeDelta: spanDegrees)
                    ))
                }
            }
        }
        .onDisappear {
            locationManager.endCompass()
        }
    }

    private func isPutt(_ stroke: Stroke) -> Bool {
        guard let club = store.availableClubs.first(where: { $0.id == stroke.clubId }) else { return false }
        return store.getTypeName(for: club) == "Putt"
    }

    private func save(par: Int) {
        ClientEventLogger.log("HolePlacementView.save.tapped", detail: ["par": .integer(par)])
        guard let coordinate = temporaryHolePosition else {
            ClientEventLogger.log("HolePlacementView.save.noCoord")
            return
        }
        // Record this user's pick so canonical resolution at future
        // round-starts (this user OR cross-user voting threshold) can
        // skip placement view. blob_id nil = manual placement, excluded
        // from voting but still beats voting for this user's own rounds.
        if let courseId = store.currentRound?.courseId {
            // Always record the coordinate, blob or not. Storing only the
            // blob id made the pick unusable without re-resolving the blob,
            // and every pick at a non-OSM course therefore had null lat/lon —
            // 15 of 15 at Wolf Hollow. The blob id still rides along, since
            // that is what cross-user voting counts.
            SupabaseSync.shared.upsertCourseHolePick(
                courseId: courseId,
                holeNumber: hole.number,
                blobId: selectedGreenBlobId,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                par: par
            )
            // And promote it to the course's shared hole record. The user
            // pointing at a green is the most authoritative source there is;
            // it must not depend on OSM knowing the course.
            SupabaseSync.shared.upsertCourseHoleLocation(
                courseId: courseId,
                number: hole.number,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                par: par
            )
        }
        store.updateHole(holeNumber: hole.number, newCoordinate: coordinate, par: par)
        ClientEventLogger.log("HolePlacementView.save.afterUpdate")
        WKInterfaceDevice.current().play(.success)
        if isEditing {
            // Edit mode: dismiss the sheet. Add mode: parent transitions automatically
            // when hole.hasLocation becomes true via the needsFlagPlacement computed property.
            dismiss()
        }
    }
}

// MARK: - Round trail

/// What the round has done so far, reduced to map geometry: the walked path,
/// each hole's shots joined in order, each hole's flag, and the launch bearing
/// the watch derived for each swing (`SwingDirection`, stored as
/// `Stroke.trajectoryHeading`).
///
/// Putts are left out of the shot dots and rays, as on the round-play map —
/// the bearing is validated on full swings only (`swing_direction/ALGORITHM.md`).
struct RoundTrail {
    struct HoleLine: Identifiable {
        let id: Int // hole number
        let coordinates: [CLLocationCoordinate2D]
    }
    struct Shot: Identifiable {
        let id: UUID
        let coordinate: CLLocationCoordinate2D
    }
    struct Flag: Identifiable {
        let id: Int // hole number
        let coordinate: CLLocationCoordinate2D
    }
    /// A swing's launch bearing drawn as a segment from where it was hit.
    struct LaunchRay: Identifiable {
        let id: UUID // stroke id
        let from: CLLocationCoordinate2D
        let to: CLLocationCoordinate2D
    }

    var path: [CLLocationCoordinate2D] = []
    var holeLines: [HoleLine] = []
    var shots: [Shot] = []
    var flags: [Flag] = []
    var rays: [LaunchRay] = []

    /// Cap on the walked-path polyline. A round samples every ~3 m, several
    /// thousand points; a few hundred draw the same shape at watch scale.
    static let maxPathPoints = 300
    /// Ray length when nothing after the shot says how far it went — the
    /// latest swing on a hole whose green isn't placed yet. Roughly a drive,
    /// so a tee shot's ray reaches toward the green it was aimed at.
    static let openRayMeters: CLLocationDistance = 180

    init(round: Round?, pathSamples: [LocationManager.PathSample], isPutt: (Stroke) -> Bool) {
        let step = max(1, (pathSamples.count + Self.maxPathPoints - 1) / Self.maxPathPoints)
        path = stride(from: 0, to: pathSamples.count, by: step).map { pathSamples[$0].coordinate }
        if let last = pathSamples.last, step > 1 { path.append(last.coordinate) }

        guard let round else { return }
        let flagByHole: [Int: CLLocationCoordinate2D] = Dictionary(
            round.holes.compactMap { hole in hole.coordinate.map { (hole.number, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        flags = flagByHole.map { Flag(id: $0.key, coordinate: $0.value) }

        let byHole = Dictionary(grouping: round.strokes.filter { !$0.isPenalty }, by: \.holeNumber)
        for (number, strokes) in byHole {
            let ordered = strokes.sorted { $0.strokeNumber < $1.strokeNumber }
            let flag = flagByHole[number]
            let full = ordered.filter { !isPutt($0) }
            // Same connector as the round-play map: full shots in order, then
            // the first putt — or the flag when the hole ended off the green.
            var line = full.map(\.coordinate)
            if let firstPutt = ordered.first(where: isPutt) {
                line.append(firstPutt.coordinate)
            } else if let flag, !line.isEmpty {
                line.append(flag)
            }
            if line.count >= 2 { holeLines.append(HoleLine(id: number, coordinates: line)) }
            shots += full.map { Shot(id: $0.id, coordinate: $0.coordinate) }
            rays += Self.launchRays(ordered: ordered, flag: flag, isPutt: isPutt)
        }
    }

    /// Launch rays for one hole's strokes, in stroke order, penalties already
    /// removed. Each ray is as long as the shot actually went — to the next
    /// stroke, else the flag — so its end sits beside where the ball finished
    /// and the gap between the two is the shot's curve.
    static func launchRays(ordered: [Stroke], flag: CLLocationCoordinate2D?,
                           isPutt: (Stroke) -> Bool) -> [LaunchRay] {
        ordered.enumerated().compactMap { index, stroke in
            guard let bearing = stroke.trajectoryHeading, !isPutt(stroke) else { return nil }
            let next = index + 1 < ordered.count ? ordered[index + 1].coordinate : flag
            let length = next.map { distanceMeters(stroke.coordinate, $0) } ?? openRayMeters
            return LaunchRay(id: stroke.id, from: stroke.coordinate,
                             to: destination(from: stroke.coordinate, bearing: bearing, meters: length))
        }
    }

    static func distanceMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    static func destination(from start: CLLocationCoordinate2D, bearing: Double,
                            meters: CLLocationDistance) -> CLLocationCoordinate2D {
        let r = 6_371_000.0
        let d = meters / r
        let theta = bearing * .pi / 180
        let lat1 = start.latitude * .pi / 180
        let lon1 = start.longitude * .pi / 180
        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(theta))
        let lon2 = lon1 + atan2(sin(theta) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2))
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }
}

/// Map styling for a `RoundTrail`. Every collection is pre-filtered so the
/// ForEach bodies carry no `if` — MapContentBuilder has dropped content
/// behind conditionals inside a ForEach.
struct RoundTrailContent: MapContent {
    let trail: RoundTrail
    let pathColor: Color

    var body: some MapContent {
        if trail.path.count >= 2 {
            MapPolyline(coordinates: trail.path)
                .stroke(pathColor.opacity(0.4), lineWidth: 1.5)
        }
        ForEach(trail.holeLines) { hole in
            MapPolyline(coordinates: hole.coordinates)
                .stroke(.white.opacity(0.75), lineWidth: 1)
        }
        LaunchRaysContent(rays: trail.rays)
        ForEach(trail.shots) { shot in
            Annotation("", coordinate: shot.coordinate, anchor: .center) {
                Circle()
                    .fill(.white)
                    .frame(width: 4, height: 4)
                    .opacity(0.85)
            }
        }
        ForEach(trail.flags) { flag in
            Annotation("", coordinate: flag.coordinate, anchor: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 1) {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.85))
                    Text("\(flag.id)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                .shadow(color: .black, radius: 1.5)
            }
        }
    }
}

/// Swing launch bearings — cyan dashes, distinct from the white shot
/// connector (where the ball went), the yellow OSM centerline and the grey
/// ghost round.
struct LaunchRaysContent: MapContent {
    let rays: [RoundTrail.LaunchRay]

    var body: some MapContent {
        ForEach(rays) { ray in
            MapPolyline(coordinates: [ray.from, ray.to])
                .stroke(.cyan.opacity(0.85),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3]))
        }
    }
}

// MARK: - Facing marker

/// The user dot plus a wedge pointing the way the watch faces. Observes the
/// compass itself, so a heading tick redraws this marker and nothing else.
struct FacingDot: View {
    @ObservedObject var compass: LocationManager.Compass
    let color: Color
    let diameter: CGFloat
    /// Map camera rotation; the wedge turns by heading minus this.
    let mapHeading: CLLocationDirection

    var body: some View {
        ZStack {
            if let degrees = compass.degrees {
                FacingWedge()
                    .fill(LinearGradient(colors: [color.opacity(0.85), color.opacity(0)],
                                         startPoint: .bottom, endPoint: .top))
                    .frame(width: 22, height: 26)
                    .offset(y: -13)
                    .rotationEffect(.degrees(degrees - mapHeading))
            }
            Circle()
                .fill(color)
                .frame(width: diameter, height: diameter)
                .shadow(color: .white, radius: 2)
                .shadow(color: .black.opacity(0.3), radius: 1)
        }
        // Square and centred on the dot, so `.center` anchoring keeps the dot
        // on the coordinate and the wedge rotates about it.
        .frame(width: 52, height: 52)
    }
}

/// A narrow fan with its point at the bottom centre.
struct FacingWedge: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.15))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.15),
                       control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.15))
        p.closeSubpath()
        return p
    }
}
