import SwiftUI

struct RoundDetailView: View {
    @ObservedObject var store: DataStore
    let round: Round
    @State private var showingResumeRound = false
    @State private var showingDeleteConfirmation = false
    @State private var selectedHoleNumber: Int?
    @State private var showingHole = false
    @Environment(\.dismiss) private var dismiss

    private var course: Course? {
        store.courses.first { $0.id == round.courseId }
    }

    private var holesWithStrokes: [(hole: Hole?, strokes: [Stroke])] {
        guard let course = course else { return [] }

        return course.holes.map { hole in
            let strokesForHole = round.strokes.filter { $0.holeNumber == hole.number }
            return (hole: hole, strokes: strokesForHole)
        }
    }

    private var totalScore: Int {
        round.strokes.count
    }

    private var totalPar: Int? {
        guard let course = course else { return nil }
        let pars = course.holes.compactMap { $0.par }
        if pars.count == course.holes.count {
            return pars.reduce(0, +)
        }
        return nil
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(round.courseName)
                                .font(.title2)
                                .fontWeight(.bold)
                            Text(round.date.formatted(date: .long, time: .shortened))
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            // Course info
                            if let course = course {
                                HStack(spacing: 12) {
                                    if let rating = course.rating {
                                        Text("Rating: \(String(format: "%.1f", rating))")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    if let slope = course.slope {
                                        Text("Slope: \(slope)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.top, 2)
                            }
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 4) {
                            Text("\(totalScore)")
                                .font(.system(size: 36, weight: .bold))
                                .foregroundColor(.blue)
                            if let par = totalPar {
                                let diff = totalScore - par
                                Text(diff >= 0 ? "+\(diff)" : "\(diff)")
                                    .font(.headline)
                                    .foregroundColor(diff > 0 ? .red : (diff < 0 ? .green : .gray))
                            }
                        }
                    }

                    if course != nil {
                        Button(action: {
                            showingResumeRound = true
                        }) {
                            Label("Edit Round", systemImage: "pencil")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }
                }
                .padding(.vertical, 8)
            }

            Section("Scorecard") {
                ForEach(holesWithStrokes, id: \.hole?.id) { holeData in
                    if let hole = holeData.hole {
                        HoleScoreRow(
                            hole: hole,
                            strokes: holeData.strokes,
                            store: store,
                            onLongPress: {
                                selectedHoleNumber = hole.number
                                showingHole = true
                            }
                        )
                    }
                }
            }
        }
        .navigationTitle("Round Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    showingDeleteConfirmation = true
                }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
            }
        }
        .confirmationDialog("Delete Round", isPresented: $showingDeleteConfirmation) {
            Button("Delete Round", role: .destructive) {
                store.deleteRound(round)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this round? This action cannot be undone.")
        }
        .navigationDestination(isPresented: $showingResumeRound) {
            if let course = course {
                HolePlayView(store: store, course: course, resumingRound: round)
            }
        }
        .navigationDestination(isPresented: $showingHole) {
            if let course = course, let holeNumber = selectedHoleNumber {
                HolePlayView(store: store, course: course, resumingRound: round, startingHoleNumber: holeNumber)
            }
        }
    }
}

struct HoleScoreRow: View {
    let hole: Hole
    let strokes: [Stroke]
    let store: DataStore
    let onLongPress: () -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                isExpanded.toggle()
            }) {
                HStack {
                    Text("Hole \(hole.number)")
                        .font(.headline)
                        .foregroundColor(.primary)

                    Spacer()

                    if let par = hole.par {
                        Text("Par \(par)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                    }

                    Text("\(strokes.count)")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(scoreColor(for: hole, strokes: strokes.count))
                        .frame(minWidth: 30)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .onLongPressGesture {
                onLongPress()
            }

            if isExpanded && !strokes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(strokes) { stroke in
                        StrokeDetailRow(stroke: stroke, store: store)
                    }
                }
                .padding(.leading, 16)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }

    private func scoreColor(for hole: Hole, strokes: Int) -> Color {
        guard let par = hole.par else { return .primary }
        let diff = strokes - par
        if diff < 0 { return .green }
        if diff > 0 { return .red }
        return .primary
    }
}

struct StrokeDetailRow: View {
    let stroke: Stroke
    let store: DataStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Stroke \(stroke.strokeNumber)")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                Text(store.getClub(byId: stroke.clubId)?.name ?? "Unknown")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.2))
                    .cornerRadius(4)
            }

            if hasDetails {
                HStack(spacing: 12) {
                    if let direction = stroke.direction {
                        DetailBadge(text: direction.displayName, color: badgeColor(severity: direction.severity))
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }

    private var hasDetails: Bool {
        stroke.direction != nil
    }

    private func badgeColor(severity: Int) -> Color {
        switch severity {
        case 2: return .red.opacity(0.3)
        case 1: return .yellow.opacity(0.3)
        default: return .green.opacity(0.3)
        }
    }
}

struct DetailBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color)
            .cornerRadius(4)
    }
}
