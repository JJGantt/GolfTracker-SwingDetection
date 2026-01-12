import SwiftUI

struct WatchHomeView: View {
    @StateObject private var store = WatchDataStore.shared
    @StateObject private var connectivity = WatchConnectivityManager.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // App icon and title
                Image(systemName: "figure.golf")
                    .font(.system(size: 50))
                    .foregroundColor(.green)

                Text("Golf Tracker")
                    .font(.headline)

                Spacer()

                // Main action button
                if let round = store.currentRound, !round.holes.isEmpty {
                    // Active round exists - show Continue button
                    NavigationLink(destination: ActiveRoundView()) {
                        Label("Continue Round", systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                } else {
                    // No active round - show Start Quick Round
                    Button(action: {
                        store.startQuickRound()
                    }) {
                        Label("Start Quick Round", systemImage: "flag.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }

                // Motion Test button (always visible)
                NavigationLink(destination: AccelTestView()) {
                    Label("Motion Test", systemImage: "waveform.path.ecg")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)

                Spacer()

                // Connection status indicator
                if connectivity.isActivated {
                    if connectivity.isReachable {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                            Text("iPhone Connected")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                            Text("iPhone Not Reachable")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding()
        }
    }
}

#Preview {
    WatchHomeView()
}
