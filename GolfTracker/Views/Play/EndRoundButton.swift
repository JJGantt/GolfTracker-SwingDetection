import SwiftUI

/// Manual "End Round" button shown at the bottom of the round-summary
/// scorecard sheet. Confirmation alert prevents accidental taps; the action
/// sets `Round.endedAt` which clears the round from `currentRound` and
/// returns the user to the home screen via `onEnded`.
struct EndRoundButton: View {
    let round: Round
    let store: DataStore
    let onEnded: () -> Void

    @State private var showingConfirm = false

    var body: some View {
        Button {
            showingConfirm = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "flag.checkered")
                Text("End Round")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.red.opacity(0.9))
            .foregroundColor(.white)
            .cornerRadius(12)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(.thinMaterial)
        .alert("End Round?", isPresented: $showingConfirm) {
            Button("End Round", role: .destructive) {
                store.endRound(round, reason: "manual")
                onEnded()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This marks the round as finished and returns you to the home screen.")
        }
    }
}
