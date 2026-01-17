import SwiftUI
import MapKit

struct EditHoleView: View {
    @ObservedObject var store: WatchDataStore
    let locationManager: LocationManager
    let hole: Hole
    @Binding var isPresented: Bool

    @State private var position: MapCameraPosition = .automatic
    @State private var temporaryHolePosition: CLLocationCoordinate2D?
    @FocusState private var isMapFocused: Bool
    @State private var shouldMaintainFocus = true

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

                    // Show temporary or current hole position
                    if let holePosition = temporaryHolePosition ?? hole.coordinate {
                        Annotation("", coordinate: holePosition) {
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
                Text("Edit Hole \(hole.number)")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Spacer()
            }
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
            // Focus the map immediately for crown zoom
            isMapFocused = true

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
        .onChange(of: isMapFocused) { _, newValue in
            // If focus is lost and we should maintain it, re-focus
            if !newValue && shouldMaintainFocus {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isMapFocused = true
                }
            }
        }
    }

    private func saveHoleLocation(par: Int) {
        guard let coordinate = temporaryHolePosition else { return }

        // Stop maintaining focus before dismissing
        shouldMaintainFocus = false

        // Update hole location and par via store
        store.updateHole(holeNumber: hole.number, newCoordinate: coordinate, par: par)

        // Haptic feedback
        WKInterfaceDevice.current().play(.success)

        // Dismiss view
        isPresented = false
    }
}
