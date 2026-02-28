import SwiftUI
import CoreLocation

struct StatsView: View {
    @EnvironmentObject var store: DataStore
    @State private var showingClubManagement = false

    var body: some View {
        NavigationStack {
            Group {
                if store.playerStats.totalRounds == 0 {
                    emptyState
                } else {
                    statsList
                }
            }
            .navigationTitle("Stats")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingClubManagement = true } label: {
                        Image(systemName: "figure.golf")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        store.rebuildPlayerStats()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showingClubManagement) {
                ClubManagementView()
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView(
            "No Data Yet",
            systemImage: "chart.bar.xaxis",
            description: Text("Complete a round to see your stats here")
        )
    }

    // MARK: - Stats List

    private var statsList: some View {
        let stats = store.playerStats
        return List {
            overallSection(stats)
            shortGameSection(stats)
            clubDistancesSection(stats)
            courseHistorySection(stats)
            footerSection(stats)
        }
    }

    // MARK: - Overall Section

    private func overallSection(_ stats: PlayerStats) -> some View {
        Section("Overview") {
            HStack(spacing: 0) {
                BigStatCell(
                    label: "Rounds",
                    value: "\(stats.totalRounds)",
                    unit: nil
                )
                Divider()
                BigStatCell(
                    label: "Avg Score",
                    value: stats.avgScoreVsPar.map { formatScore($0) } ?? "--",
                    unit: "vs par"
                )
                Divider()
                BigStatCell(
                    label: "Best",
                    value: stats.bestScoreVsPar.map { formatScore(Double($0)) } ?? "--",
                    unit: "vs par"
                )
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Short Game Section

    private func shortGameSection(_ stats: PlayerStats) -> some View {
        Section("Short Game") {
            if let putts = stats.avgPuttsPerRound {
                StatRow(label: "Putts / Round", value: String(format: "%.1f", putts))
            }
            if let puttsPerHole = stats.avgPuttsPerHole {
                StatRow(label: "Putts / Hole", value: String(format: "%.2f", puttsPerHole))
            }
            if let gir = stats.girPercent {
                StatRow(label: "Greens in Regulation", value: String(format: "%.0f%%", gir))
            }
            if let fwy = stats.fairwayHitPercent {
                StatRow(label: "Fairways Hit", value: String(format: "%.0f%%", fwy))
            }
            if let dev = stats.avgDeviationDegrees {
                StatRow(label: "Avg Shot Deviation", value: String(format: "%.0f°", dev))
            }
        }
    }

    // MARK: - Club Distances Section

    private func clubDistancesSection(_ stats: PlayerStats) -> some View {
        // Order by club type list order, skip types with no data
        let orderedStats = store.clubTypes.compactMap { ct -> ClubDistanceStats? in
            stats.perClubTypeStats[ct.id.uuidString]
        }
        guard !orderedStats.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(
            Section("Club Distances") {
                ForEach(orderedStats, id: \.id) { cds in
                    ClubDistanceRow(stats: cds, fallback: store.clubTypes.first(where: { $0.id == cds.id })?.averageDistance)
                }
            }
        )
    }

    // MARK: - Course History Section

    private func courseHistorySection(_ stats: PlayerStats) -> some View {
        let courses = stats.perCourseStats.values.sorted { $0.lastPlayed > $1.lastPlayed }
        guard !courses.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(
            Section("By Course") {
                ForEach(courses, id: \.courseId) { cs in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(cs.courseName)
                                .font(.headline)
                            Spacer()
                            Text("\(cs.roundsPlayed) round\(cs.roundsPlayed == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 16) {
                            if let avg = cs.avgScoreVsPar {
                                Label(
                                    "Avg \(formatScore(avg))",
                                    systemImage: "chart.line.uptrend.xyaxis"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            if let best = cs.bestScoreVsPar {
                                Label(
                                    "Best \(formatScore(Double(best)))",
                                    systemImage: "trophy"
                                )
                                .font(.caption)
                                .foregroundStyle(best < 0 ? .green : .secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        )
    }

    // MARK: - Footer

    private func footerSection(_ stats: PlayerStats) -> some View {
        Section {
            Text("Updated \(stats.lastUpdated.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Helpers

    private func formatScore(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        if rounded > 0 { return "+\(rounded)" }
        if rounded < 0 { return "\(rounded)" }
        return "E"
    }
}

// MARK: - Supporting Views

struct BigStatCell: View {
    let label: String
    let value: String
    let unit: String?

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let unit = unit {
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
        }
    }
}

struct ClubDistanceRow: View {
    let stats: ClubDistanceStats
    let fallback: Int?  // static default from ClubTypeData if no real data

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(stats.name)
                    .font(.body)
                Text("\(stats.sampleCount) shot\(stats.sampleCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(stats.isReliable ? Color.secondary : Color.orange)
            }
            Spacer()
            if stats.isReliable {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(stats.trimmedAvgDistanceYards.rounded())) yds")
                        .font(.body)
                        .fontWeight(.medium)
                    Text("± \(Int(stats.stdDevYards.rounded()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(stats.avgDistanceYards.rounded())) yds")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Text("need \(max(0, 5 - stats.sampleCount)) more")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
