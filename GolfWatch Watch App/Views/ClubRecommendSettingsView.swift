import SwiftUI
import WatchKit

struct ClubRecommendSettingsView: View {
    @ObservedObject var store: WatchDataStore
    @Binding var manualClubOverride: Bool
    @Binding var showingDistanceEditor: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Club Recommend")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.bottom, 4)

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

                if store.clubPredictionMode == .manual {
                    Button(action: {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showingDistanceEditor = true
                        }
                    }) {
                        Text("Edit Distances")
                            .font(.system(size: 13))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.blue.opacity(0.9))
                            .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.top, 4)
                }
            }
            .padding()
        }
    }
}
