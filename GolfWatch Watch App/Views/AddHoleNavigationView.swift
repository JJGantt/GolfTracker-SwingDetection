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
        ZStack {
            // Map layer
            MapReader { proxy in
                Map(position: $position) {
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

                    // User location dot — direction-less. Heading capture
                    // is gone, so the previous arrow had no real heading
                    // to point with. Tinted with playgroup color to match
                    // the main round-play map.
                    if let userLocation = locationManager.location {
                        Annotation("", coordinate: userLocation.coordinate) {
                            Circle()
                                .fill(Color(hex: store.myPlayerColor))
                                .frame(width: isEditing ? 7 : 9, height: isEditing ? 7 : 9)
                                .shadow(color: .white, radius: 2)
                                .shadow(color: .black.opacity(0.3), radius: 1)
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
