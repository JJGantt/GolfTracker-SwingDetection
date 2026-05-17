import SwiftUI
import WatchKit

struct OptionsView: View {
    @ObservedObject var store: WatchDataStore
    @ObservedObject private var swingDetector = SwingDetectionManager.shared
    @Environment(\.dismiss) private var dismissSheet

    // Bindings for state that needs to be modified
    @Binding var showingOptions: Bool
    @Binding var showingEditHole: Bool
    @Binding var showingDistanceEditor: Bool
    @Binding var isFullViewMode: Bool
    @Binding var manualClubOverride: Bool
    @Binding var navigateToViewSettings: Bool
    @Binding var navigateToClubRecommend: Bool
    @Binding var isPlacingTarget: Bool
    @Binding var minimalScreenMode: Bool

    // Closures for actions
    var updateMapPosition: () -> Void
    var updateNoHoleMapPosition: () -> Void
    var dismissParent: () -> Void

    @State private var showingMultiplayer = false
    @State private var showingEndRoundConfirm = false
    @AppStorage(PlaygroupChannel.liveDotsEnabledKey) private var liveDotsEnabled = true

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Top row: Hole navigation
                if let hole = store.currentHole, let round = store.currentRound {
                    HStack(spacing: 12) {
                        // Left arrow - previous hole
                        Button(action: {
                            store.navigateToPreviousHole()
                        }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 40, height: 40)
                                .background(Color.blue.opacity(0.9))
                                .clipShape(Circle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(store.currentHoleIndex == 0)
                        .opacity(store.currentHoleIndex == 0 ? 0.3 : 1.0)

                        // Hole number
                        Text("Hole \(hole.number)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)

                        // Right arrow or plus - next hole or add hole
                        if store.currentHoleIndex < round.holes.count - 1 {
                            // Next hole exists - show right arrow
                            Button(action: {
                                store.navigateToNextHole()
                            }) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 40, height: 40)
                                    .background(Color.blue.opacity(0.9))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(PlainButtonStyle())
                        } else {
                            // Last hole - show plus to add new hole
                            Button(action: {
                                store.addNextHole()
                                showingOptions = false
                                WKInterfaceDevice.current().play(.click)
                            }) {
                                Image(systemName: "plus")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 40, height: 40)
                                    .background(Color.green.opacity(0.9))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal, 8)
                }

                // Second row: Target placement and Talk
                HStack(spacing: 8) {
                    // Target placement — toggles the on-map target placement
                    // mode. Was previously a button on the main screen
                    // bottom-left; that slot is now the Undo button. Target
                    // placement is the lower-frequency action so it lives
                    // here in the pull-up.
                    Button(action: {
                        showingOptions = false
                        isPlacingTarget = true
                        WKInterfaceDevice.current().play(.click)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "scope")
                                .font(.system(size: 14, weight: .bold))
                            Text("Target")
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.blue.opacity(0.9))
                        .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(store.currentHole == nil)
                    .opacity(store.currentHole == nil ? 0.5 : 1.0)

                    // Push-to-talk (walkie-talkie) — press-and-hold to record,
                    // release to send. Visible whether or not in a playgroup;
                    // disabled when no playgroup is active so the row layout
                    // stays stable instead of jumping around. Sheet stays open
                    // during the press so the user can release in-place.
                    OptionsTalkButton()
                }
                .padding(.horizontal, 8)

                // Third row: Penalty (+1 stroke per tap, sheet stays open
                // so user can tap multiple times) and Battery toggle.
                HStack(spacing: 8) {
                    Button(action: {
                        store.addPenaltyStroke()
                        WKInterfaceDevice.current().play(.click)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 14, weight: .bold))
                            Text("Penalty")
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.orange.opacity(0.9))
                        .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(store.currentHole.map { store.isHoleCompleted($0.number) } ?? true)
                    .opacity((store.currentHole.map { store.isHoleCompleted($0.number) } ?? true) ? 0.5 : 1.0)

                    // Battery / minimal-screen-mode toggle. Was a tiny
                    // floating button on the main map; moved here to keep
                    // the main view uncluttered. Tap toggles in place;
                    // sheet stays open so the user can preview the change
                    // by closing.
                    Button(action: {
                        minimalScreenMode.toggle()
                        WKInterfaceDevice.current().play(.click)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: minimalScreenMode ? "batteryblock.fill" : "batteryblock")
                                .font(.system(size: 14, weight: .bold))
                            Text("Battery")
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(minimalScreenMode ? Color.green.opacity(0.9) : Color.gray.opacity(0.9))
                        .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 8)

                // Home — moved to its own row below to make room for the
                // Battery toggle one row up.
                Button(action: {
                    SwingDetectionManager.shared.stopMonitoring()
                    showingOptions = false
                    dismissParent()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "house.fill")
                            .font(.system(size: 14, weight: .bold))
                        Text("Home")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.gray.opacity(0.9))
                    .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.horizontal, 8)

                // End Round — manual finish. Confirmation alert prevents
                // accidental taps; the action sets `endedAt` which clears
                // the round from `currentRound` everywhere.
                if store.currentRound != nil {
                    Button(action: {
                        showingEndRoundConfirm = true
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "flag.checkered")
                                .font(.system(size: 14, weight: .bold))
                            Text("End Round")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.9))
                        .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.horizontal, 8)
                }

                // Edit Hole — moved down here so the second-row spot can be
                // used for the higher-frequency Talk button. Edit Hole is a
                // setup/correction action, fine to be one row lower.
                Button(action: {
                    showingOptions = false
                    showingEditHole = true
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "flag")
                            .font(.system(size: 14, weight: .bold))
                        Text("Edit Hole")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.yellow.opacity(0.9))
                    .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.horizontal, 8)

                // Settings section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Settings")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)

                    settingsNavButton("View") {
                        showingOptions = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            navigateToViewSettings = true
                        }
                    }

                    settingsNavButton("Club Recommend") {
                        showingOptions = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            navigateToClubRecommend = true
                        }
                    }

                    settingsNavButton("Multiplayer") {
                        showingMultiplayer = true
                    }

                    Toggle("Share live position", isOn: $liveDotsEnabled)
                        .font(.system(size: 14))

                    Toggle("Limit 800Hz to putter only", isOn: $swingDetector.raw800PutterOnly)
                        .font(.system(size: 14))
                }
            }
            .padding()
        }
        .sheet(isPresented: $showingMultiplayer) {
            NavigationStack {
                MultiplayerView()
            }
        }
        .alert("End Round?", isPresented: $showingEndRoundConfirm) {
            Button("End Round", role: .destructive) {
                store.endRound(reason: "manual")
                showingOptions = false
                dismissParent()
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    @ViewBuilder
    private func settingsNavButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 13))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}

// MARK: - Radio Button Component

struct RadioButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? .green : .gray)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .white : .gray)
                Spacer()
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Radio Toggle Style

struct RadioToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: {
            configuration.isOn.toggle()
        }) {
            HStack {
                Image(systemName: configuration.isOn ? "circle.inset.filled" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(configuration.isOn ? .green : .gray)
                configuration.label
                    .foregroundColor(configuration.isOn ? .white : .gray)
                Spacer()
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}
