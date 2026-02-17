import SwiftUI
import MapKit

struct EditHoleView: View {
    @ObservedObject var store: WatchDataStore
    let locationManager: LocationManager
    let hole: Hole
    @Binding var isPresented: Bool

    @State private var position: MapCameraPosition = .automatic
    @State private var temporaryHolePosition: CLLocationCoordinate2D?
    @State private var selectedGreenBlobId: UUID?
    @State private var isManualPlacement = false
    private let greenSnapDistanceMeters: CLLocationDistance = 50

    private var greenCandidates: [HoleDetectionBlob] {
        guard store.currentRound?.holeDetectionEnabled == true else { return [] }
        return store.filteredGreenCandidates(for: store.currentRound?.courseId)
    }

    var body: some View {
        ZStack {
            // Map layer
            MapReader { proxy in
                Map(position: $position) {
                    // Show user location
                    if let userLocation = locationManager.location {
                        Annotation("", coordinate: userLocation.coordinate) {
                            Image(systemName: "location.north.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.blue)
                                .rotationEffect(.degrees(locationManager.heading ?? 0))
                                .shadow(color: .white, radius: 2)
                                .shadow(color: .black.opacity(0.3), radius: 1)
                        }
                    }

                    // Show flag for existing hole or manual placement (not blob selection)
                    if selectedGreenBlobId == nil,
                       let holePosition = temporaryHolePosition ?? hole.coordinate {
                        Annotation("", coordinate: holePosition) {
                            Image(systemName: "flag.fill")
                                .foregroundColor(.yellow)
                                .font(.system(size: 24))
                                .shadow(color: .black, radius: 2)
                        }
                    }

                    // Suggested greens from phone-side detection
                    ForEach(greenCandidates) { blob in
                        if blob.polygonCoordinates.count >= 3,
                           let first = blob.polygonCoordinates.first {
                            let outline = blob.polygonCoordinates + [first]
                            let isSelected = blob.id == selectedGreenBlobId
                            MapPolyline(coordinates: outline)
                                .stroke(
                                    isSelected ? Color.yellow : Color.white,
                                    lineWidth: isSelected ? 4 : 1.5
                                )
                        }
                    }
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
                    }
                }
            }
            .ignoresSafeArea()

            // Top overlay — .padding(.top, 8) controls how far down the row sits
            VStack(spacing: 2) {
                ZStack(alignment: .leading) {
                    // Centered hole label
                    Text("Edit Hole \(hole.number)")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.gray.opacity(0.6))
                        .clipShape(Capsule())
                        .frame(maxWidth: .infinity)

                    // Left-aligned manual toggle
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

                // Distance to placed hole
                if let holePos = temporaryHolePosition,
                   let userLoc = locationManager.location {
                    let yards = Int(userLoc.distance(from: CLLocation(latitude: holePos.latitude, longitude: holePos.longitude)) * 1.09361)
                    Text("\(yards) yds")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .ignoresSafeArea()

            // Par buttons overlay - only show when hole has been moved
            if temporaryHolePosition != nil {
                VStack {
                    Spacer()

                    HStack(spacing: 8) {
                        // Par 3 button
                        Button(action: { saveHoleLocation(par: 3) }) {
                            ZStack {
                                Circle()
                                    .fill(Color.green.opacity(0.95))
                                    .frame(width: 50, height: 50)
                                    .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)

                                if hole.par == 3 {
                                    Circle()
                                        .stroke(Color.white, lineWidth: 3)
                                        .frame(width: 50, height: 50)
                                }

                                Text("3")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())

                        // Par 4 button
                        Button(action: { saveHoleLocation(par: 4) }) {
                            ZStack {
                                Circle()
                                    .fill(Color.green.opacity(0.95))
                                    .frame(width: 50, height: 50)
                                    .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)

                                if hole.par == 4 {
                                    Circle()
                                        .stroke(Color.white, lineWidth: 3)
                                        .frame(width: 50, height: 50)
                                }

                                Text("4")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())

                        // Par 5 button
                        Button(action: { saveHoleLocation(par: 5) }) {
                            ZStack {
                                Circle()
                                    .fill(Color.green.opacity(0.95))
                                    .frame(width: 50, height: 50)
                                    .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)

                                if hole.par == 5 {
                                    Circle()
                                        .stroke(Color.white, lineWidth: 3)
                                        .frame(width: 50, height: 50)
                                }

                                Text("5")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 16)
                }
                .ignoresSafeArea()
            }
        }
        .onAppear {
            // Center map on hole location or user location
            let spanInMeters: CLLocationDistance = 320.0 // ~350 yards
            let spanDegrees = spanInMeters / 111000.0

            if let center = hole.coordinate ?? locationManager.location?.coordinate {
                position = .region(MKCoordinateRegion(
                    center: center,
                    span: MKCoordinateSpan(latitudeDelta: spanDegrees, longitudeDelta: spanDegrees)
                ))
            }
        }
    }

    private func saveHoleLocation(par: Int) {
        guard let coordinate = temporaryHolePosition else { return }

        // Update hole location and par via store
        store.updateHole(holeNumber: hole.number, newCoordinate: coordinate, par: par)

        // Haptic feedback
        WKInterfaceDevice.current().play(.success)

        // Dismiss view
        isPresented = false
    }
}
