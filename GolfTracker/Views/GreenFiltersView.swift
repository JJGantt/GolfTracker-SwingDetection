import SwiftUI

struct GreenFiltersView: View {
    @EnvironmentObject var store: DataStore

    var body: some View {
        Form {
            Section {
                Toggle("Filter blobs", isOn: Binding(
                    get: { store.holeFilterSettings.enabled },
                    set: { newValue in applyChange { store.holeFilterSettings.enabled = newValue } }
                ))
            } footer: {
                Text("When off, all detected blobs pass through unchanged.")
            }

            Section("Filters") {
                stepperRow("Min g_score", value: store.holeFilterSettings.minGreennessScore, range: 0...10000, step: 25) { v in
                    store.holeFilterSettings.minGreennessScore = v
                }
                stepperRow("Max rank", value: store.holeFilterSettings.maxRank, range: 1...500, step: 1) { v in
                    store.holeFilterSettings.maxRank = v
                }
                doubleStepperRow("Min width", value: store.holeFilterSettings.minWidth, range: 0...80, step: 1) { v in
                    store.holeFilterSettings.minWidth = v
                }
                doubleStepperRow("Max elongation", value: store.holeFilterSettings.maxElongation, range: 1.0...10.0, step: 0.1) { v in
                    store.holeFilterSettings.maxElongation = v
                }
            }
        }
        .navigationTitle("Blob filters")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func applyChange(_ block: () -> Void) {
        block()
        store.saveHoleFilterSettings()
        WatchConnectivityManager.shared.sendHoleFilterSettings(store.holeFilterSettings)
    }

    @ViewBuilder
    private func stepperRow(_ label: String, value: Int, range: ClosedRange<Int>, step: Int, set: @escaping (Int) -> Void) -> some View {
        HStack {
            Stepper(value: Binding(get: { value }, set: { v in applyChange { set(v) } }), in: range, step: step) {
                Text(label).font(.caption)
            }
            Text("\(value)")
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func doubleStepperRow(_ label: String, value: Double, range: ClosedRange<Double>, step: Double, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Stepper(value: Binding(get: { value }, set: { v in applyChange { set(v) } }), in: range, step: step) {
                Text(label).font(.caption)
            }
            Text(String(format: "%.1f", value))
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
    }
}
