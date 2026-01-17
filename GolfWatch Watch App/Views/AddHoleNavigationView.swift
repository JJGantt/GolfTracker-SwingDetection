import SwiftUI
import MapKit

struct AddHoleNavigationView: View {
    @ObservedObject var store: WatchDataStore
    @ObservedObject var locationManager: LocationManager
    @Environment(\.dismiss) private var dismiss

    @State private var position: MapCameraPosition = .automatic
    @State private var temporaryHolePosition: CLLocationCoordinate2D?
    @FocusState private var isMapFocused: Bool
    @State private var shouldMaintainFocus = true

    private var currentHoleNumber: Int {
        store.currentHole?.number ?? 1
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
                                .font(.system(size: 30))
                                .foregroundColor(.blue)
                                .rotationEffect(.degrees(locationManager.heading ?? 0))
                                .shadow(color: .white, radius: 2)
                                .shadow(color: .black.opacity(0.3), radius: 1)
                        }
                    }

                    // Show temporary hole position
                    if let holePos = temporaryHolePosition {
                        Annotation("", coordinate: holePos) {
                            Image(systemName: "flag.fill")
                                .foregroundColor(.yellow)
                                .font(.system(size: 24))
                                .shadow(color: .black, radius: 2)
                        }
                    }
                }
                .modifier(HideMapControlsModifier(isInteractive: true))
                .focusable()
                .focused($isMapFocused)
                .onTapGesture { screenCoord in
                    if let coordinate = proxy.convert(screenCoord, from: .local) {
                        temporaryHolePosition = coordinate
                        WKInterfaceDevice.current().play(.click)
                    }
                }
            }
            .ignoresSafeArea()

            // Top hole number overlay
            VStack {
                Text("Hole \(currentHoleNumber)")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Spacer()
            }
            .ignoresSafeArea()

            // Par buttons overlay - only show when hole position is set
            if temporaryHolePosition != nil {
                VStack {
                    Spacer()

                    HStack(spacing: 8) {
                        // Par 3 button
                        Button(action: { saveHole(par: 3) }) {
                            ZStack {
                                Circle()
                                    .fill(Color.green.opacity(0.95))
                                    .frame(width: 50, height: 50)
                                    .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)

                                Text("3")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())

                        // Par 4 button
                        Button(action: { saveHole(par: 4) }) {
                            ZStack {
                                Circle()
                                    .fill(Color.green.opacity(0.95))
                                    .frame(width: 50, height: 50)
                                    .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)

                                Text("4")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())

                        // Par 5 button
                        Button(action: { saveHole(par: 5) }) {
                            ZStack {
                                Circle()
                                    .fill(Color.green.opacity(0.95))
                                    .frame(width: 50, height: 50)
                                    .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)

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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .onAppear {
            // Start location tracking
            locationManager.requestPermission()
            locationManager.startTracking()

            // Focus the map immediately for crown zoom
            isMapFocused = true

            // Center map on user location
            if let userLocation = locationManager.location {
                let spanInMeters: CLLocationDistance = 320.0 // ~350 yards
                let spanDegrees = spanInMeters / 111000.0

                position = .region(MKCoordinateRegion(
                    center: userLocation.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: spanDegrees, longitudeDelta: spanDegrees)
                ))
            }
        }
        .onChange(of: isMapFocused) { _, newValue in
            // If focus is lost and we should maintain it, re-focus
            if !newValue && shouldMaintainFocus {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isMapFocused = true
                }
            }
        }
    }

    private func saveHole(par: Int) {
        guard let coordinate = temporaryHolePosition,
              let currentHole = store.currentHole else { return }

        // Stop maintaining focus
        shouldMaintainFocus = false

        // Update the current hole's coordinates and par
        store.updateHole(holeNumber: currentHole.number, newCoordinate: coordinate, par: par)

        // Haptic feedback
        WKInterfaceDevice.current().play(.success)

        // No need to dismiss - parent view will automatically switch
        // when it detects the hole now has a location
    }
}
