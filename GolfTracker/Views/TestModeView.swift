import SwiftUI
import MapKit
import CoreLocation

/// Developer-only view for cross-device GPS simulation. Tap anywhere on
/// the map to set the simulated coordinate; the watch (and this phone)
/// will react as if that were a real GPS fix. Toggle off to resume real
/// GPS. Hidden behind a long-press gesture in `SettingsView`.
struct TestModeView: View {
    @ObservedObject private var service = TestModeService.shared

    @State private var position: MapCameraPosition = .automatic
    @State private var draftCoord: CLLocationCoordinate2D?

    var body: some View {
        VStack(spacing: 0) {
            // Status + toggle
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Test Mode Enabled", isOn: Binding(
                    get: { service.enabled },
                    set: { newValue in
                        Task { await service.setEnabled(newValue) }
                    }
                ))
                if let coord = service.simulatedCoord {
                    Text(String(format: "Simulated: %.6f, %.6f", coord.latitude, coord.longitude))
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))

            // Map: tap to drop pin
            MapReader { proxy in
                Map(position: $position) {
                    if let coord = service.simulatedCoord {
                        Annotation("Sim", coordinate: coord) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title)
                                .foregroundColor(.red)
                                .shadow(color: .black.opacity(0.4), radius: 2)
                        }
                    }
                }
                .mapStyle(.hybrid)
                .onTapGesture { screenLocation in
                    guard let coord = proxy.convert(screenLocation, from: .local) else { return }
                    draftCoord = coord
                    Task { await service.setSimulatedCoord(coord) }
                }
                .onAppear {
                    // If we already have a sim coord saved, center on it.
                    if let coord = service.simulatedCoord {
                        position = .region(MKCoordinateRegion(
                            center: coord,
                            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                        ))
                    }
                }
            }
        }
        .navigationTitle("Test Mode")
        .navigationBarTitleDisplayMode(.inline)
    }
}
