import SwiftUI

struct InRoundScorecardView: View {
    let round: Round
    let currentHoleNumber: Int?
    let store: DataStore

    private var holesPlayed: [(hole: Hole, strokes: [Stroke])] {
        round.holes
            .sorted { $0.number < $1.number }
            .compactMap { hole -> (hole: Hole, strokes: [Stroke])? in
                let s = round.strokes.filter { $0.holeNumber == hole.number }
                guard !s.isEmpty else { return nil }
                return (hole, s.sorted { $0.strokeNumber < $1.strokeNumber })
            }
    }

    private var runningTotal: (strokes: Int, par: Int?) {
        let completedHoles = holesPlayed.filter { round.isHoleCompleted($0.hole.number) }
        let strokes = completedHoles.flatMap { $0.strokes }.filter { !$0.isPenalty }.count
        let pars = completedHoles.compactMap { $0.hole.par }
        let par = pars.isEmpty ? nil : pars.reduce(0, +)
        return (strokes, par)
    }

    var body: some View {
        NavigationStack {
            List {
                // Running total header
                Section {
                    let total = runningTotal
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(round.courseName)
                                .font(.headline)
                            Text("\(holesPlayed.filter { round.isHoleCompleted($0.hole.number) }.count) holes complete")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(total.strokes)")
                                .font(.title2).fontWeight(.bold)
                            if let par = total.par {
                                let diff = total.strokes - par
                                Text(diff == 0 ? "E" : (diff > 0 ? "+\(diff)" : "\(diff)"))
                                    .font(.subheadline).fontWeight(.semibold)
                                    .foregroundStyle(diff < 0 ? .green : diff > 0 ? .red : .secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Per-hole scorecard
                Section("Scorecard") {
                    ForEach(holesPlayed, id: \.hole.id) { data in
                        HoleInRoundRow(
                            hole: data.hole,
                            strokes: data.strokes,
                            isCompleted: round.isHoleCompleted(data.hole.number),
                            isCurrent: data.hole.number == currentHoleNumber,
                            store: store
                        )
                    }
                }
            }
            .navigationTitle("Scorecard")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct HoleInRoundRow: View {
    let hole: Hole
    let strokes: [Stroke]
    let isCompleted: Bool
    let isCurrent: Bool
    let store: DataStore

    private var strokeCount: Int { strokes.filter { !$0.isPenalty }.count }
    private var penaltyCount: Int { strokes.filter { $0.isPenalty }.count }

    private var puttCount: Int {
        strokes.filter { s in
            store.getClub(byId: s.clubId)
                .flatMap { store.getClubType(byId: $0.clubTypeId) }?.name == "Putt"
        }.count
    }

    private var scoreVsPar: Int? {
        guard let par = hole.par, isCompleted else { return nil }
        return strokeCount - par
    }

    var body: some View {
        HStack(spacing: 12) {
            // Hole number with active indicator
            ZStack {
                if isCurrent {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 28, height: 28)
                }
                Text("\(hole.number)")
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundStyle(isCurrent ? .white : .primary)
            }
            .frame(width: 28)

            // Par
            if let par = hole.par {
                Text("Par \(par)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
            } else {
                Text("--")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, alignment: .leading)
            }

            // Putt count (if any putts logged)
            if puttCount > 0 {
                Label("\(puttCount)", systemImage: "flag.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Penalty indicator
            if penaltyCount > 0 {
                Label("\(penaltyCount)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()

            // Score
            HStack(spacing: 6) {
                if let diff = scoreVsPar, diff != 0 {
                    Text(diff > 0 ? "+\(diff)" : "\(diff)")
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(diff < 0 ? .green : .red)
                }
                Text(isCompleted ? "\(strokeCount)" : "\(strokes.count)")
                    .font(.title3).fontWeight(.bold)
                    .foregroundStyle(scoreColor)
            }
        }
        .padding(.vertical, 2)
        .opacity(isCompleted || isCurrent ? 1.0 : 0.6)
    }

    private var scoreColor: Color {
        guard let diff = scoreVsPar else { return .primary }
        if diff < 0 { return .green }
        if diff > 0 { return .red }
        return .primary
    }
}
