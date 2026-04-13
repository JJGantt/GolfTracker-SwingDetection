import SwiftUI
import MapKit

// MARK: - GPS Indicator & Distance Readout
//
// Distance-to-hole / distance-to-target math, the hole-info overlay (yards or
// "GRN" pill), and the GPS power-mode driver that steps between .full / .moderate
// / .off based on distance and selected club.
extension ActiveRoundView {
    var distanceToHole: Int? {
        guard let userLocation = locationManager.location,
              let hole = store.currentHole,
              let holeCoord = hole.coordinate else { return nil }

        let holeLocation = CLLocation(latitude: holeCoord.latitude, longitude: holeCoord.longitude)
        let distanceInMeters = userLocation.distance(from: holeLocation)
        return Int(distanceInMeters * 1.09361)
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

                    // Main container: Yards + H/P row
                    VStack(alignment: .leading, spacing: 4) {
                        Text(locationManager.gpsPowerMode == .off ? "GRN" : (distanceToHole.map { String($0) } ?? "XXX"))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundColor(locationManager.gpsPowerMode == .off ? .green : .white)

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

                    // Separate strokes container
                    Text("S: \(store.strokeCount(for: hole))")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Color(red: 0.55, green: 0.85, blue: 0.55))
                        .padding(4)
                        .background(Color.black.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .fixedSize()
                }
                // No else case - when no hole exists, onAppear navigates to HolePlacementView
            }
            .padding(.leading, 6)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ignoresSafeArea()
        .opacity(isPlacingTarget || isPlacingPenalty ? 0 : 1)
    }

    func handleLocationChange() {
        if !isInteractiveMapMode {
            restoreCalculatedMapPosition()
        }

        guard store.clubPredictionMode != .off else { return }
        let nowOnGreen = isOnCurrentGreen
        if nowOnGreen && !onGreenOverride && !manualClubOverride {
            if let putterIndex = putterClubIndex() {
                isAutoSelectingClub = true
                onGreenOverride = true
                selectedClubIndex = Double(putterIndex)
                updateSwingDetectorClub()
                isAutoSelectingClub = false
            }
            return
        }

        if !nowOnGreen && onGreenOverride {
            onGreenOverride = false
            applyClubPrediction()
        }
    }

    func handleDistanceToHoleChange(_ newDistance: Int?) {
        // Update GPS power mode based on distance (skip if GPS is off for putter)
        if locationManager.gpsPowerMode != .off {
            updateGPSForDistance()
        }

        guard !manualClubOverride,
              !onGreenOverride,
              autoAddedStrokeId == nil,
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
