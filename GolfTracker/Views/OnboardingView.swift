import SwiftUI
import CoreLocation

struct OnboardingView: View {
    @Binding var hasSeenOnboarding: Bool
    // Observed so the view re-renders when authorizationStatus flips after
    // the system permission dialog. Plain `let` capture meant the row was
    // stuck on "Open Settings" until the next app launch re-read the status.
    @ObservedObject private var locationManager = LocationManager.shared
    @State private var didRequestLocation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to StrokeSaver")
                    .font(.largeTitle.bold())
                Text("Before you start, enable the permission below.")
                    .foregroundColor(.secondary)
            }
            .padding(.top, 40)

            primerRow(
                icon: "location.fill",
                title: "Location",
                body: "Used to measure distances to the hole and record where each shot was hit from.",
                granted: isLocationGranted,
                action: requestLocation,
                didRequest: didRequestLocation
            )

            Spacer()

            Button(action: { hasSeenOnboarding = true }) {
                Text(isLocationGranted ? "Continue" : "Skip for now")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isLocationGranted ? Color.accentColor : Color.gray.opacity(0.3))
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
        }
        .padding(24)
        .interactiveDismissDisabled(true)
    }

    private var isLocationGranted: Bool {
        locationManager.authorizationStatus == .authorizedWhenInUse ||
            locationManager.authorizationStatus == .authorizedAlways
    }

    private func requestLocation() {
        if didRequestLocation && locationManager.authorizationStatus == .denied {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            return
        }
        didRequestLocation = true
        locationManager.requestPermission()
    }

    @ViewBuilder
    private func primerRow(icon: String, title: String, body: String, granted: Bool, action: @escaping () -> Void, didRequest: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(body).font(.subheadline).foregroundColor(.secondary)
                if granted {
                    Label("Enabled", systemImage: "checkmark.circle.fill")
                        .font(.caption.bold())
                        .foregroundColor(.green)
                        .padding(.top, 4)
                } else {
                    Button(action: action) {
                        Text(didRequest ? "Open Settings" : "Enable")
                            .font(.subheadline.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
                }
            }
        }
    }
}
