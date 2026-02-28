import SwiftUI
import WatchKit

struct PredictGreenSettingsView: View {
    @ObservedObject var store: WatchDataStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Predict Green")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.bottom, 4)

                paramRow("Min Area", value: Double(store.holeFilterSettings.minArea), format: "%.0f", unit: "",
                         dec: { store.holeFilterSettings.minArea = max(0, store.holeFilterSettings.minArea - 50) },
                         inc: { store.holeFilterSettings.minArea = min(5000, store.holeFilterSettings.minArea + 50) })

                paramRow("Min Width", value: store.holeFilterSettings.minWidth, format: "%.0f", unit: "",
                         dec: { store.holeFilterSettings.minWidth = max(0, store.holeFilterSettings.minWidth - 1) },
                         inc: { store.holeFilterSettings.minWidth = min(80, store.holeFilterSettings.minWidth + 1) })

                paramRow("Max Elong", value: store.holeFilterSettings.maxElongation, format: "%.1f", unit: "",
                         dec: { store.holeFilterSettings.maxElongation = max(1.0, store.holeFilterSettings.maxElongation - 0.1) },
                         inc: { store.holeFilterSettings.maxElongation = min(6.0, store.holeFilterSettings.maxElongation + 0.1) })

                paramRow("Min Score", value: Double(store.holeFilterSettings.minGreennessScore), format: "%.0f", unit: "",
                         dec: { store.holeFilterSettings.minGreennessScore = max(0, store.holeFilterSettings.minGreennessScore - 25) },
                         inc: { store.holeFilterSettings.minGreennessScore = min(1200, store.holeFilterSettings.minGreennessScore + 25) })
            }
            .padding()
        }
    }

    @ViewBuilder
    func paramRow(_ label: String, value: Double, format: String, unit: String,
                  dec: @escaping () -> Void, inc: @escaping () -> Void) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                Spacer()
                Text("\(String(format: format, value))\(unit.isEmpty ? "" : " \(unit)")")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            HStack {
                Button(action: dec) {
                    Text("-")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.gray.opacity(0.3))
                        .cornerRadius(6)
                }
                .buttonStyle(PlainButtonStyle())
                Button(action: inc) {
                    Text("+")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.gray.opacity(0.3))
                        .cornerRadius(6)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
}
