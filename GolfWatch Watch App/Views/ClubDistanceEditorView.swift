import SwiftUI

struct ClubDistanceEditorView: View {
    @ObservedObject var store: WatchDataStore
    @Environment(\.dismiss) private var dismiss
    @State var selectedIndex: Int = 0
    @State var editingDistance: Double = 100
    @FocusState var isCrownFocused: Bool

    // Get enabled clubs with their type names (excludes clubs not eligible for prediction)
    var enabledClubs: [(club: ClubData, typeName: String)] {
        store.availableClubs.compactMap { club in
            guard let clubType = store.clubTypes.first(where: { $0.id == club.clubTypeId }) else {
                return nil
            }
            guard !ClubPredictionManager.excludedFromPrediction.contains(clubType.name) else {
                return nil
            }
            return (club, clubType.name)
        }
    }

    var currentClubName: String {
        guard selectedIndex < enabledClubs.count else { return "" }
        return enabledClubs[selectedIndex].typeName
    }

    var currentDistance: Int {
        Int(editingDistance.rounded())
    }

    var isCurrentClubDisabled: Bool {
        guard selectedIndex < enabledClubs.count else { return false }
        return store.disabledPredictionClubs.contains(enabledClubs[selectedIndex].typeName)
    }

    var body: some View {
        VStack(spacing: 6) {
            Spacer()
                .frame(height: 10)

            Text("Adjust Distances")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)

            // Club navigation with name between arrows
            HStack(spacing: 16) {
                Button(action: previousClub) {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(selectedIndex > 0 ? .white : .gray.opacity(0.4))
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(selectedIndex == 0)

                Text(currentClubName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .frame(minWidth: 60)

                Button(action: nextClub) {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(selectedIndex < enabledClubs.count - 1 ? .white : .gray.opacity(0.4))
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(selectedIndex >= enabledClubs.count - 1)
            }

            // Distance display
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(currentDistance)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundColor(isCurrentClubDisabled ? .gray : .green)
                Text("yd")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            // Instructions
            Text("Use crown to adjust distance")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            // Disable from predictions toggle
            Button(action: toggleClubDisabled) {
                HStack(spacing: 4) {
                    Image(systemName: isCurrentClubDisabled ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 14))
                    Text(isCurrentClubDisabled ? "Disabled from predictions" : "Enabled for predictions")
                        .font(.system(size: 11))
                }
                .foregroundColor(isCurrentClubDisabled ? .red : .green)
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.top, 4)
        }
        .focusable()
        .focused($isCrownFocused)
        .modifier(DistanceCrownRotationModifier(distance: $editingDistance))
        .onAppear {
            isCrownFocused = true
            loadCurrentClubDistance()
        }
        .onDisappear {
            saveCurrentDistance()
        }
    }

    func loadCurrentClubDistance() {
        guard selectedIndex < enabledClubs.count else { return }
        let club = enabledClubs[selectedIndex].club
        guard let clubType = store.clubTypes.first(where: { $0.id == club.clubTypeId }) else { return }
        let average = ClubPredictionManager.shared.getAverage(
            for: clubType,
            mode: .manual,
            customAverages: store.customClubAverages
        )
        editingDistance = Double(average)
    }

    func saveCurrentDistance() {
        guard selectedIndex < enabledClubs.count else { return }
        let typeName = enabledClubs[selectedIndex].typeName
        var averages = store.customClubAverages
        averages[typeName] = currentDistance
        store.customClubAverages = averages
    }

    func previousClub() {
        guard selectedIndex > 0 else { return }
        saveCurrentDistance()
        selectedIndex -= 1
        loadCurrentClubDistance()
        WKInterfaceDevice.current().play(.click)
    }

    func nextClub() {
        guard selectedIndex < enabledClubs.count - 1 else { return }
        saveCurrentDistance()
        selectedIndex += 1
        loadCurrentClubDistance()
        WKInterfaceDevice.current().play(.click)
    }

    func toggleClubDisabled() {
        guard selectedIndex < enabledClubs.count else { return }
        let typeName = enabledClubs[selectedIndex].typeName
        if store.disabledPredictionClubs.contains(typeName) {
            store.disabledPredictionClubs.remove(typeName)
        } else {
            store.disabledPredictionClubs.insert(typeName)
        }
        WKInterfaceDevice.current().play(.click)
    }
}
