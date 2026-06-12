import SwiftUI

// MARK: - Club Prediction & Selection
//
// Prediction-logic helpers, auto-add overlay club commit, and swing-detector
// club-name sync (which also drives GPS power modes when the putter is picked).
extension ActiveRoundView {
    func putterClubIndex() -> Int? {
        clubs.indices.first { index in
            guard let clubType = store.clubTypes.first(where: { $0.id == clubs[index].clubTypeId }) else { return false }
            return clubType.name == "Putt"
        }
    }

    func applyClubPrediction() {
        guard store.clubPredictionMode != .off,
              let distance = distanceToHole else { return }
        // On-green polygon override already auto-selected putter for this
        // green and is the authoritative "use the putter" signal. Bail so
        // we don't fight it — without this, recording a putt re-runs the
        // distance-based predictor with Putt disabled (see below) and
        // picks a wedge for the 2yd-from-pin reading.
        if onGreenOverride { return }
        // Conditionally drop "Putt" from the candidate set when an OSM green
        // polygon exists for the current hole — polygon containment +
        // `greenPutterMarginYards` is the authoritative putter trigger in
        // that case. Without a polygon, leave putter eligible so the
        // distance predictor can pick it as the fallback (matches the
        // yardage-based path in `handleDetectedSwingChange`).
        var disabled = store.disabledPredictionClubs
        if currentHoleGreenBlob != nil {
            disabled.insert("Putt")
        }
        if let predictedIndex = ClubPredictionManager.shared.predictClubIndex(
            forDistance: distance,
            clubs: clubs,
            clubTypes: store.clubTypes,
            mode: store.clubPredictionMode,
            customAverages: store.customClubAverages,
            disabledClubs: disabled
        ) {
            // Leave isAutoSelectingClub TRUE — the .onChange handler will
            // observe and clear it. See `handleSelectedClubIndexChange` for
            // the rationale. Synchronously clearing it here would cause the
            // auto-selection to be misclassified as manual.
            isAutoSelectingClub = true
            selectedClubIndex = Double(predictedIndex)
            updateSwingDetectorClub()
        }
    }

    func updateSwingDetectorClub() {
        guard let club = selectedClub else { return }
        let newTypeName = store.getTypeName(for: club)
        swingDetector.selectedClubTypeName = newTypeName

        if newTypeName == "Putt" {
            // Putter = on or beside the green — the densest cross-round
            // overlap on the hole, i.e. the elevation pipeline's per-hole
            // sync point. Run full fidelity so those crossings land in the
            // right 3m cells. (Used to force .moderate for battery; the
            // few minutes per green are worth the sync quality.)
            locationManager.setGPSPowerMode(.full)
        } else {
            // Non-putter — let distance-based logic pick full vs moderate.
            updateGPSForDistance()
        }
    }

    func handleSelectedClubIndexChange() {
        WatchDiagnostics.shared.recordCrownTick()
        // Crown binding is Double, ticks many times per second. The actual
        // selected club only changes once per integer step. Avoid running
        // any of the heavy per-tick work (swing-detector publisher fire,
        // GPS power mode read, SwiftData lookup) until the integer index
        // actually changes.
        let rounded = clubs.isEmpty
            ? 0
            : Int(selectedClubIndex.rounded()) % clubs.count
        if rounded != lastSettledClubIndex {
            lastSettledClubIndex = rounded
            WatchDiagnostics.shared.recordClubIntegerChange()
            // Observe-and-clear the auto-selection flag atomically. SwiftUI's
            // .onChange runs asynchronously, so a setter that did
            // `isAutoSelectingClub = true; selectedClubIndex = X;
            // isAutoSelectingClub = false` in one synchronous block leaves
            // the flag false by the time this handler actually runs — the
            // auto-selection looks like a manual one. Result: every auto-
            // selection used to silently set `manualClubOverride = true`,
            // which in turn killed all future auto club-switching until the
            // next stroke recording cleared it. Setters now leave the flag
            // set; we clear it here in the handler.
            let wasAutoSelection = isAutoSelectingClub
            isAutoSelectingClub = false
            if !wasAutoSelection && store.clubPredictionMode != .off {
                manualClubOverride = true
            }
            updateSwingDetectorClub()
        }

        // Cheap per-tick work — local @State only, no publisher fires
        // beyond the view itself. Drives the "scrolling" animation.
        if !isCrownScrolling {
            withAnimation(.easeInOut(duration: 0.15)) {
                isCrownScrolling = true
            }
        }

        crownScrollTimer?.invalidate()
        crownScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                isCrownScrolling = false
            }
        }
    }
}
