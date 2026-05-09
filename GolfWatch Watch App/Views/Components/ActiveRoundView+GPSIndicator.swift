import SwiftUI
import MapKit

// MARK: - GPS Indicator & Distance Readout
//
// Distance-to-hole / distance-to-target math, the hole-info overlay (yards),
// and the GPS power-mode driver that steps between .full and .moderate
// based on distance and selected club.
extension ActiveRoundView {
    var distanceToHole: Int? {
        guard let userLocation = locationManager.location,
              let hole = store.currentHole,
              let holeCoord = hole.coordinate else { return nil }

        let holeLocation = CLLocation(latitude: holeCoord.latitude, longitude: holeCoord.longitude)
        let distanceInMeters = userLocation.distance(from: holeLocation)
        return Int(distanceInMeters * 1.09361)
    }

    /// On-screen yardage readout: live GPS distance from user to the hole.
    /// We previously showed scorecard tee-yardage when no strokes had been
    /// recorded yet (pre-tee-shot), but reverted to always-live since
    /// tee-yardage was confusing when the user wasn't actually at the tee
    /// (auto-advanced from another hole, restarted the app mid-walk, etc).
    var displayedDistanceToHole: Int? { distanceToHole }

    /// True when the user's GPS is inside the current hole's green
    /// polygon. Source-agnostic — uses the same `filteredGreenCandidates`
    /// lookup `AutoAdvanceMonitor` does, so OSM and blob-detected
    /// courses both work. The yardage readout flips its color based on
    /// this — instant "you're here" signal without waiting for the
    /// number itself to read 0.
    var isUserOnCurrentGreen: Bool {
        guard let userCoord = locationManager.location?.coordinate,
              let round = store.currentRound,
              let hole = store.currentHole,
              let greenMarker = hole.coordinate else { return false }
        let greenBlob = store.filteredGreenCandidates(for: round.courseId)
            .first { $0.contains(greenMarker) }
        guard let blob = greenBlob, !blob.polygon.isEmpty else { return false }
        return blob.contains(userCoord)
    }

    func distanceToTarget(_ target: CLLocationCoordinate2D) -> Int? {
        guard let userLocation = locationManager.location else { return nil }

        let targetLocation = CLLocation(
            latitude: target.latitude,
            longitude: target.longitude
        )

        let distanceInMeters = userLocation.distance(from: targetLocation)
        return Int(distanceInMeters * 1.09361) // Convert to yards
    }

    @ViewBuilder
    var holeInfoOverlay: some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 4) {
                if let hole = store.currentHole {
                    let parText = hole.par.map { String($0) } ?? "-"

                    // Always show live yardage to the hole — the "GRN"
                    // putter-selected pill is gone for now (we'll come back
                    // to it later). Green-polygon detection still runs in
                    // the background to drive auto-putter-select / auto-
                    // advance, it just doesn't change this readout.
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(displayedDistanceToHole.map { String($0) } ?? "XXX")
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .foregroundColor(isUserOnCurrentGreen
                                    ? Color(red: 0.4, green: 0.95, blue: 0.4)
                                    : .white)
                            ElevationDeltaLabel()
                        }

                        HStack(spacing: 8) {
                            Text("H: \(hole.number)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                            Text("P: \(parText)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                        }
                    }
                    .padding(4)
                    .background(Color.black.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .fixedSize()

                    // Strokes pill — total strokes on this hole. Same
                    // green pill as before. Putts go on the map above
                    // the green polygon, not here.
                    Text("S: \(store.strokeCount(for: hole))")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Color(red: 0.55, green: 0.85, blue: 0.55))
                        .padding(4)
                        .background(Color.black.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .fixedSize()

                    // Penalty stroke count, smaller orange "P: N" pill below
                    // the score readout. Hidden when zero — penalties are
                    // rare so the readout shouldn't clutter the overlay
                    // unless the user has actually taken one.
                    let penaltyCount = store.penaltyCount(for: hole)
                    if penaltyCount > 0 {
                        Text("P: \(penaltyCount)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.4))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .fixedSize()
                    }
                }
                // No else case - when no hole exists, onAppear navigates to HolePlacementView
            }
            .padding(.leading, 6)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ignoresSafeArea()
        .opacity(isPlacingTarget ? 0 : 1)
    }

    func handleLocationChange() {
        if !isInteractiveMapMode {
            restoreCalculatedMapPosition()
        }

        // Log green-detection state. Fires on transitions of nowOnGreen,
        // AND on the first call per round, AND throttled to once per 5s
        // otherwise so we get periodic snapshots even when user is far
        // from any green. Logged BEFORE the clubPredictionMode guard so
        // we can tell if the guard is what's killing the chain.
        let courseId = store.currentRound?.courseId
        let candidateCount = courseId.map { store.filteredGreenCandidates(for: $0).count } ?? 0
        let blob = currentHoleGreenBlob
        let nowOnGreen = isOnCurrentGreen
        let now = Date()
        let transition = nowOnGreen != lastLoggedOnGreen
        let firstCall = lastLoggedGreenAt == nil
        let throttledTick = lastLoggedGreenAt.map { now.timeIntervalSince($0) >= 5.0 } ?? true
        if transition || firstCall || throttledTick {
            lastLoggedOnGreen = nowOnGreen
            lastLoggedGreenAt = now
            ClientEventLogger.log("green.state", detail: [
                "trigger": .string(transition ? "transition" : (firstCall ? "first" : "tick")),
                "nowOnGreen": .bool(nowOnGreen),
                "candidateCount": .integer(candidateCount),
                "hasMatchingBlobForHole": .bool(blob != nil),
                "predictionMode": .string("\(store.clubPredictionMode.rawValue)"),
                "manualClubOverride": .bool(manualClubOverride),
                "onGreenOverride": .bool(onGreenOverride),
                "userLat": locationManager.location.map { .double($0.coordinate.latitude) } ?? .null,
                "userLon": locationManager.location.map { .double($0.coordinate.longitude) } ?? .null,
                "holeLat": store.currentHole?.latitude.map { .double($0) } ?? .null,
                "holeLon": store.currentHole?.longitude.map { .double($0) } ?? .null
            ])
        }

        guard store.clubPredictionMode != .off else { return }
        // Leave isAutoSelectingClub TRUE here — the .onChange handler will
        // observe and clear it. See `handleSelectedClubIndexChange` for the
        // race rationale.
        if nowOnGreen && !onGreenOverride && !manualClubOverride {
            if let putterIndex = putterClubIndex() {
                ClientEventLogger.log("club.autoSelect.putter.polygon", detail: [
                    "hasMatchingBlobForHole": .bool(blob != nil),
                    "marginYd": .double(UserDefaults.standard.object(forKey: "greenPutterMarginYards").flatMap { ($0 as? NSNumber)?.doubleValue } ?? 2.0)
                ])
                isAutoSelectingClub = true
                onGreenOverride = true
                selectedClubIndex = Double(putterIndex)
                updateSwingDetectorClub()
                // Don't reset isAutoSelectingClub here — handler observes/clears.
            }
            return
        }

        if !nowOnGreen && onGreenOverride {
            onGreenOverride = false
            applyClubPrediction()
        }
    }

    func handleDistanceToHoleChange(_ newDistance: Int?) {
        updateGPSForDistance()

        // Note: NOT gated on autoAddedStrokeId. The overlay's crown-driven
        // club (`overlayClubIndex`) is independent of the main club index
        // (`selectedClubIndex`) which is what distance-prediction targets
        // for the NEXT stroke. Used to be gated here, which caused the
        // main club to stay stuck on whatever was predicted at swing time
        // until the user tapped X on the overlay.
        guard !manualClubOverride,
              !onGreenOverride,
              store.clubPredictionMode != .off,
              newDistance != nil else { return }
        applyClubPrediction()
    }

    func updateGPSForDistance() {
        let threshold = swingDetector.gpsModerateYards
        guard threshold > 0, let distance = distanceToHole else {
            locationManager.setGPSPowerMode(.full)
            return
        }
        locationManager.setGPSPowerMode(distance > threshold ? .moderate : .full)
    }
}
