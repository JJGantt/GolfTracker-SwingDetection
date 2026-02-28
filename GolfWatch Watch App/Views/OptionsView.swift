import SwiftUI
import WatchKit

struct OptionsView: View {
    @ObservedObject var store: WatchDataStore
    @Environment(\.dismiss) private var dismissSheet

    // Bindings for state that needs to be modified
    @Binding var showingOptions: Bool
    @Binding var showingEditHole: Bool
    @Binding var showingDistanceEditor: Bool
    @Binding var isFullViewMode: Bool
    @Binding var manualClubOverride: Bool
    @Binding var navigateToAccelTest: Bool
    @Binding var navigateToViewSettings: Bool
    @Binding var navigateToClubRecommend: Bool
    @Binding var navigateToPredictGreen: Bool
    @Binding var isPlacingPenalty: Bool

    // Closures for actions
    var updateMapPosition: () -> Void
    var updateNoHoleMapPosition: () -> Void
    var deleteLastStroke: () -> Void
    var dismissParent: () -> Void
    var canUndo: Bool

    @State private var showingUndoConfirmation = false

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

                // Second row: Undo and Edit buttons
                HStack(spacing: 8) {
                    // Undo button - shows confirmation
                    Button(action: {
                        showingUndoConfirmation = true
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 14, weight: .bold))
                            Text("Undo")
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.red.opacity(0.9))
                        .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(!canUndo)
                    .opacity(canUndo ? 1.0 : 0.5)

                    // Edit Hole button
                    Button(action: {
                        showingOptions = false
                        showingEditHole = true
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "flag")
                                .font(.system(size: 16, weight: .bold))
                            Text("Edit")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.yellow.opacity(0.9))
                        .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 8)

                // Third row: Penalty and Home buttons
                HStack(spacing: 8) {
                    // Penalty button - enters penalty placement mode
                    Button(action: {
                        showingOptions = false
                        isPlacingPenalty = true
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

                    Button(action: {
                        SwingDetectionManager.shared.stopMonitoring()
                        showingOptions = false
                        dismissParent()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "house.fill")
                                .font(.system(size: 14, weight: .bold))
                            Text("Home")
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.gray.opacity(0.9))
                        .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
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

                    settingsNavButton("Motion Config") {
                        showingOptions = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            navigateToAccelTest = true
                        }
                    }

                    settingsNavButton("Predict Green") {
                        showingOptions = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            navigateToPredictGreen = true
                        }
                    }
                }
            }
            .padding()
        }
        .confirmationDialog("Undo Last Stroke?", isPresented: $showingUndoConfirmation, titleVisibility: .visible) {
            Button("Undo", role: .destructive) {
                deleteLastStroke()
                showingOptions = false
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
