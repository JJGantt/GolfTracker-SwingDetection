import SwiftUI
import CoreLocation

struct RoundDetailView: View {
    @ObservedObject var store: DataStore
    let round: Round
    @State private var showingResumeRound = false
    @State private var showingDeleteConfirmation = false
    @State private var selectedHoleNumber: Int?
    @State private var showingHole = false
    @Environment(\.dismiss) private var dismiss

    // MARK: - Derived Properties

    private var course: Course? {
        store.courses.first { $0.id == round.courseId }
    }

    private var nonPenaltyStrokes: [Stroke] {
        round.strokes.filter { !$0.isPenalty }
    }

    private var totalScore: Int { nonPenaltyStrokes.count }

    private var totalPar: Int? {
        let played = Set(round.strokes.map { $0.holeNumber })
        let pars = round.holes.filter { played.contains($0.number) }.compactMap { $0.par }
        return pars.isEmpty ? nil : pars.reduce(0, +)
    }

    private var scoreVsPar: Int? {
        guard let par = totalPar else { return nil }
        return totalScore - par
    }

    private var roundDuration: String? {
        let ts = round.strokes.map { $0.timestamp }.sorted()
        guard let first = ts.first, let last = ts.last, last > first else { return nil }
        let mins = Int(last.timeIntervalSince(first) / 60)
        return mins < 60 ? "\(mins)m" : "\(mins / 60)h \(mins % 60)m"
    }

    private var puttsCount: Int {
        round.strokes.filter { isPutt($0) }.count
    }

    private var girResult: (hits: Int, eligible: Int) {
        var hits = 0, eligible = 0
        for hole in round.holes {
            guard let par = hole.par else { continue }
            let holeStrokes = round.strokes.filter { $0.holeNumber == hole.number }.sorted { $0.strokeNumber < $1.strokeNumber }
            guard let firstPutt = holeStrokes.first(where: { isPutt($0) }) else { continue }
            eligible += 1
            if firstPutt.strokeNumber <= par - 1 { hits += 1 }
        }
        return (hits, eligible)
    }

    // Holes paired with their strokes, in hole-number order
    private var holesWithStrokes: [(hole: Hole, strokes: [Stroke])] {
        round.holes
            .sorted { $0.number < $1.number }
            .map { hole in
                let s = round.strokes
                    .filter { $0.holeNumber == hole.number }
                    .sorted { $0.strokeNumber < $1.strokeNumber }
                return (hole, s)
            }
            .filter { !$0.strokes.isEmpty }
    }

    // Per-club-type usage + avg distance for this round
    private var clubBreakdown: [ClubRoundEntry] {
        var groups: [UUID: (name: String, strokes: [Stroke])] = [:]
        for stroke in nonPenaltyStrokes {
            guard let club = store.getClub(byId: stroke.clubId),
                  let ct = store.getClubType(byId: club.clubTypeId) else { continue }
            if groups[ct.id] == nil { groups[ct.id] = (name: ct.name, strokes: []) }
            groups[ct.id]?.strokes.append(stroke)
        }
        return groups.map { (typeId, data) in
            let distances = shotDistances(for: data.strokes)
            let avg = distances.isEmpty ? nil : distances.reduce(0, +) / Double(distances.count)
            return ClubRoundEntry(clubTypeId: typeId, name: data.name, count: data.strokes.count, avgYards: avg)
        }
        .sorted { $0.count > $1.count }
    }

    // MARK: - Body

    var body: some View {
        List {
            headerSection
            keyStatsSection
            if !clubBreakdown.isEmpty { clubBreakdownSection }
            scorecardSection
        }
        .navigationTitle("Round Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
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
            Text("This action cannot be undone.")
        }
        .navigationDestination(isPresented: $showingResumeRound) {
            if let c = course { HolePlayView(store: store, course: c, resumingRound: round) }
        }
        .navigationDestination(isPresented: $showingHole) {
            if let c = course, let h = selectedHoleNumber {
                HolePlayView(store: store, course: c, resumingRound: round, startingHoleNumber: h)
            }
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(round.courseName)
                            .font(.title2).fontWeight(.bold)
                        Text(round.date.formatted(date: .long, time: .shortened))
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let duration = roundDuration {
                            Label(duration, systemImage: "clock")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let c = course {
                            HStack(spacing: 12) {
                                if let rating = c.rating {
                                    Text("Rating \(String(format: "%.1f", rating))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let slope = c.slope {
                                    Text("Slope \(slope)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(totalScore)")
                            .font(.system(size: 44, weight: .bold))
                        if let diff = scoreVsPar {
                            Text(formatScore(diff))
                                .font(.title3).fontWeight(.semibold)
                                .foregroundStyle(scoreColor(diff))
                        }
                        if let par = totalPar {
                            Text("Par \(par)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if course != nil {
                    Button {
                        showingResumeRound = true
                    } label: {
                        Label("Edit Round", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Key Stats Section

    private var keyStatsSection: some View {
        Section("Stats") {
            HStack(spacing: 0) {
                BigStatCell(label: "Putts", value: "\(puttsCount)", unit: nil)
                Divider()
                BigStatCell(
                    label: "GIR",
                    value: girResult.eligible > 0 ? "\(girResult.hits)/\(girResult.eligible)" : "--",
                    unit: girResult.eligible > 0 ? String(format: "%.0f%%", Double(girResult.hits) / Double(girResult.eligible) * 100) : nil
                )
                Divider()
                BigStatCell(
                    label: "Penalties",
                    value: "\(round.strokes.filter { $0.isPenalty }.count)",
                    unit: nil
                )
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Club Breakdown Section

    private var clubBreakdownSection: some View {
        Section("Clubs") {
            ForEach(clubBreakdown) { entry in
                HStack {
                    Text(entry.name)
                    Spacer()
                    HStack(spacing: 12) {
                        Text("\(entry.count)×")
                            .foregroundStyle(.secondary)
                        if let avg = entry.avgYards {
                            Text("\(Int(avg.rounded())) yds")
                                .fontWeight(.medium)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Scorecard Section

    private var scorecardSection: some View {
        Section("Scorecard") {
            ForEach(holesWithStrokes, id: \.hole.id) { data in
                HoleScoreRow(
                    hole: data.hole,
                    strokes: data.strokes,
                    store: store,
                    onLongPress: {
                        selectedHoleNumber = data.hole.number
                        showingHole = true
                    }
                )
            }
        }
    }

    // MARK: - Helpers

    private func isPutt(_ stroke: Stroke) -> Bool {
        store.getClub(byId: stroke.clubId)
            .flatMap { store.getClubType(byId: $0.clubTypeId) }?.name == "Putt"
    }

    private func shotDistances(for strokes: [Stroke]) -> [Double] {
        var results: [Double] = []
        let byHole = Dictionary(grouping: strokes, by: { $0.holeNumber })
        for (holeNumber, holeGroup) in byHole {
            let all = nonPenaltyStrokes
                .filter { $0.holeNumber == holeNumber }
                .sorted { $0.strokeNumber < $1.strokeNumber }
            for s in holeGroup {
                guard let idx = all.firstIndex(where: { $0.id == s.id }),
                      idx + 1 < all.count else { continue }
                let from = all[idx], to = all[idx + 1]
                let yards = CLLocation(latitude: from.latitude, longitude: from.longitude)
                    .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude)) * 1.09361
                if yards >= 5 && yards <= 350 { results.append(yards) }
            }
        }
        return results
    }

    private func formatScore(_ diff: Int) -> String {
        if diff > 0 { return "+\(diff)" }
        if diff < 0 { return "\(diff)" }
        return "E"
    }

    private func formatScore(_ diff: Double) -> String {
        let r = Int(diff.rounded())
        return formatScore(r)
    }

    private func scoreColor(_ diff: Int) -> Color {
        if diff < 0 { return .green }
        if diff > 0 { return .red }
        return .secondary
    }
}

// MARK: - Supporting Types

struct ClubRoundEntry: Identifiable {
    let clubTypeId: UUID
    let name: String
    let count: Int
    let avgYards: Double?
    var id: UUID { clubTypeId }
}

// MARK: - Hole Score Row

struct HoleScoreRow: View {
    let hole: Hole
    let strokes: [Stroke]
    let store: DataStore
    let onLongPress: () -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    // Hole number
                    Text("\(hole.number)")
                        .font(.headline)
                        .frame(width: 28, alignment: .leading)

                    // Par
                    if let par = hole.par {
                        Text("Par \(par)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .leading)
                    } else {
                        Text("--")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .leading)
                    }

                    Spacer()

                    // Score badge
                    let diff = hole.par.map { strokes.count - $0 }
                    HStack(spacing: 6) {
                        if let d = diff, d != 0 {
                            Text(d > 0 ? "+\(d)" : "\(d)")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(d < 0 ? .green : .red)
                        }
                        Text("\(strokes.count)")
                            .font(.title3).fontWeight(.bold)
                            .foregroundStyle(scoreForeground(strokes.count, par: hole.par))
                            .frame(minWidth: 28, alignment: .trailing)
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onLongPressGesture { onLongPress() }

            if isExpanded && !strokes.isEmpty {
                VStack(spacing: 4) {
                    ForEach(strokes) { stroke in
                        StrokeDetailRow(stroke: stroke, store: store, allHoleStrokes: strokes)
                    }
                }
                .padding(.leading, 12)
                .padding(.bottom, 6)
                .padding(.top, 2)
            }
        }
    }

    private func scoreForeground(_ strokes: Int, par: Int?) -> Color {
        guard let par = par else { return .primary }
        let diff = strokes - par
        if diff < 0 { return .green }
        if diff > 0 { return .red }
        return .primary
    }
}

// MARK: - Stroke Detail Row

struct StrokeDetailRow: View {
    let stroke: Stroke
    let store: DataStore
    let allHoleStrokes: [Stroke]

    private var clubTypeName: String {
        store.getClub(byId: stroke.clubId)
            .flatMap { store.getClubType(byId: $0.clubTypeId) }?.name ?? "?"
    }

    private var distanceYards: Int? {
        guard !stroke.isPenalty else { return nil }
        let sorted = allHoleStrokes.filter { !$0.isPenalty }.sorted { $0.strokeNumber < $1.strokeNumber }
        guard let idx = sorted.firstIndex(where: { $0.id == stroke.id }),
              idx + 1 < sorted.count else { return nil }
        let from = sorted[idx], to = sorted[idx + 1]
        let meters = CLLocation(latitude: from.latitude, longitude: from.longitude)
            .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
        let yards = meters * 1.09361
        return (yards >= 5 && yards <= 350) ? Int(yards.rounded()) : nil
    }

    var body: some View {
        HStack {
            if stroke.isPenalty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            } else {
                Text("\(stroke.strokeNumber)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .center)
            }

            Text(stroke.isPenalty ? "Penalty" : clubTypeName)
                .font(.subheadline)

            Spacer()

            if let yds = distanceYards {
                Text("\(yds) yds")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(Color(.systemGray6))
        .cornerRadius(6)
    }
}
