import SwiftUI
import WatchKit

struct ViewSettingsView: View {
    @Binding var isFullViewMode: Bool
    var updateMapPosition: () -> Void
    var updateNoHoleMapPosition: () -> Void
    var hasCurrentHole: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("View")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.bottom, 4)

                RadioButton(
                    title: "Full",
                    isSelected: isFullViewMode
                ) {
                    isFullViewMode = true
                    WKInterfaceDevice.current().play(.click)
                    if hasCurrentHole {
                        updateMapPosition()
                    } else {
                        updateNoHoleMapPosition()
                    }
                }

                RadioButton(
                    title: "Direct",
                    isSelected: !isFullViewMode
                ) {
                    isFullViewMode = false
                    WKInterfaceDevice.current().play(.click)
                    if hasCurrentHole {
                        updateMapPosition()
                    } else {
                        updateNoHoleMapPosition()
                    }
                }
            }
            .padding()
        }
    }
}
