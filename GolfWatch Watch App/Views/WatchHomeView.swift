import SwiftUI

struct WatchHomeView: View {
    @StateObject private var store = WatchDataStore.shared
    @StateObject private var connectivity = WatchConnectivityManager.shared
    @State private var navigateToActiveRound = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 5) {
                // App icon and title
                Image(systemName: "figure.golf")
                    .font(.system(size: 40))
                    .foregroundColor(.green)

                HealthKitBanner()

                Spacer()

                // Main action button
                if store.availableClubs.isEmpty {
                    // No clubs synced yet - show waiting state
                    VStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Waiting for clubs to sync...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Open iPhone app")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.gray.opacity(0.3))
                    .cornerRadius(10)
                } else if store.currentRound != nil {
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
                }


                Button(action: {
                    store.startRoundAtCurrentLocation()
                }) {
                    Label("New Round", systemImage: "flag.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(store.roundStartStatus != nil)

                // Resolver status while a round-start is in flight.
                if let status = store.roundStartStatus {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text(status)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.top, 4)
                }

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
            .navigationDestination(isPresented: $navigateToActiveRound) {
                ActiveRoundView()
            }
            // Resolver succeeded → navigate. Watching for currentRound flip to non-nil
            // when no round was active when the user tapped the button.
            .onChange(of: store.currentRound?.id) { _, newId in
                if newId != nil && store.roundStartStatus == nil {
                    navigateToActiveRound = true
                }
            }
            .sheet(item: Binding(
                get: { store.pendingPOIPicker.map { CourseCandidatesWrapper(candidates: $0) } },
                set: { _ in store.pickPOICandidate(nil) }
            )) { wrapper in
                CoursePickerView(candidates: wrapper.candidates) { picked in
                    store.pickPOICandidate(picked)
                }
            }
            .alert(
                store.pendingExistingCoursePrompt.map { "Play \($0.courseName)?" } ?? "",
                isPresented: Binding(
                    get: { store.pendingExistingCoursePrompt != nil },
                    set: { if !$0 { store.answerExistingCoursePrompt(confirmed: false) } }
                ),
                presenting: store.pendingExistingCoursePrompt
            ) { _ in
                Button("Play") { store.answerExistingCoursePrompt(confirmed: true) }
                Button("Different course", role: .cancel) { store.answerExistingCoursePrompt(confirmed: false) }
            } message: { match in
                Text("\(Int(match.distanceMeters))m away")
            }
        }
    }
}

// Identifiable wrapper so we can drive a `.sheet(item:)` off the candidates array.
private struct CourseCandidatesWrapper: Identifiable {
    let candidates: [RoundResolver.POICandidate]
    var id: String { candidates.map(\.name).joined(separator: "|") }
}

private struct CoursePickerView: View {
    let candidates: [RoundResolver.POICandidate]
    let onPick: (RoundResolver.POICandidate?) -> Void

    var body: some View {
        NavigationStack {
            List(candidates, id: \.self) { c in
                Button {
                    onPick(c)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(.body)
                        Text("\(Int(c.distanceMeters)) m")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Pick course")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onPick(nil) }
                }
            }
        }
    }
}

#Preview {
    WatchHomeView()
}
