import SwiftUI
import MapKit
import WatchKit

struct OptionsView: View {
    @ObservedObject var store: WatchDataStore
    @ObservedObject var satelliteCache: WatchSatelliteCacheManager
    @Environment(\.dismiss) private var dismissSheet

    // Bindings for state that needs to be modified
    @Binding var showingOptions: Bool
    @Binding var showingEditHole: Bool
    @Binding var showingDistanceEditor: Bool
    @Binding var isFullViewMode: Bool
    @Binding var manualClubOverride: Bool
    @Binding var navigateToAccelTest: Bool

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
                if let hole = store.currentHole, let round = store.currentRound, let course = store.getCourse(for: round) {
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
                        if store.currentHoleIndex < course.holes.count - 1 {
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
                        .padding(.vertical, 12)
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
                        .padding(.vertical, 12)
                        .background(Color.orange.opacity(0.9))
                        .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 8)

                // Third row: Home button
                HStack(spacing: 8) {
                    Button(action: {
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
                        .padding(.vertical, 12)
                        .background(Color.gray.opacity(0.9))
                        .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 8)

                VStack(alignment: .leading, spacing: 8) {
                    // Full View Mode Toggle
                    Toggle(isOn: Binding(
                        get: { isFullViewMode },
                        set: { newValue in
                            isFullViewMode = newValue
                            WKInterfaceDevice.current().play(.click)
                            if store.currentHole != nil {
                                updateMapPosition()
                            } else {
                                updateNoHoleMapPosition()
                            }
                        }
                    )) {
                        Text("Full View")
                            .font(.system(size: 13))
                    }
                    .toggleStyle(RadioToggleStyle())
                    .padding(.horizontal, 8)

                    // Satellite Mode Toggle
                    let hasSatelliteImages = satelliteCache.hasCachedImages(for: store.currentRound?.courseId ?? UUID())
                    Toggle(isOn: Binding(
                        get: { store.satelliteModeEnabled },
                        set: { newValue in
                            store.satelliteModeEnabled = newValue
                            WKInterfaceDevice.current().play(.click)
                        }
                    )) {
                        Text("Satellite")
                            .font(.system(size: 13))
                    }
                    .toggleStyle(RadioToggleStyle())
                    .disabled(!hasSatelliteImages)
                    .opacity(hasSatelliteImages ? 1.0 : 0.5)
                    .padding(.horizontal, 8)

                    // Motion Config button
                    Button(action: {
                        showingOptions = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            navigateToAccelTest = true
                        }
                    }) {
                        HStack {
                            Image(systemName: "waveform.path.ecg")
                                .font(.system(size: 14))
                            Text("Motion Config")
                                .font(.system(size: 13))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)

                    // Predict Club setting
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Predict Club")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                                Text("auto-select club based on distance")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            // Edit button for Manual mode
                            if store.clubPredictionMode == .manual {
                                Button(action: {
                                    showingOptions = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        showingDistanceEditor = true
                                    }
                                }) {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(8)
                                        .background(Color.blue.opacity(0.9))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.bottom, 2)

                        // Mode selector as radio buttons
                        ForEach(ClubPredictionMode.allCases, id: \.self) { mode in
                            RadioButton(
                                title: mode.rawValue,
                                isSelected: store.clubPredictionMode == mode
                            ) {
                                store.clubPredictionMode = mode
                                manualClubOverride = false
                                WKInterfaceDevice.current().play(.click)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
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
