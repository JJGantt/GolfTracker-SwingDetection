import SwiftUI

/// Vertical scorecard — one row per hole, columns vary by what's available.
/// Used in both iOS (full-screen sheet) and watchOS (sheet from active round).
///
/// Solo single-tee layout (most common):
/// ```
/// │ Hole │ Par │ Yds │ Score │
/// ```
///
/// When the round was started without a tee selection (course not in
/// GolfCourseAPI), the Yds column is omitted.
///
/// Front-9 / Back-9 / Total subtotal rows separate the hole list with a
/// visual break. Multi-player and multi-tee column variants will land in a
/// later milestone (see docs/MULTIPLAYER.md).
struct ScorecardView: View {
    let round: Round
    /// Cached per-hole data for the round's selected tee, keyed by hole number.
    /// Nil when the round has no `selectedTeeId` (course not in GolfCourseAPI).
    let teeHoles: [Int: CachedCourseTeeHole]?
    /// Display name of the selected tee for the column header. Nil when no tee.
    let teeName: String?

    /// Multiplayer payload. When non-empty, the scorecard switches to a
    /// per-player score column layout with merged-by-tee yardage columns.
    /// When empty (solo round, or playgroup load-in-flight), falls back to
    /// the single-player layout above.
    var players: [PlaygroupChannel.ScorecardPlayer] = []

    private var isMultiplayer: Bool { players.count >= 2 }

    private var holesSorted: [Hole] {
        round.holes.sorted { $0.number < $1.number }
    }

    private var showsYardage: Bool { teeHoles != nil && teeName != nil }

    /// Distinct tees in use across the playgroup, in display order.
    /// Same teeId from multiple players collapses to one column.
    private var distinctTees: [(teeId: UUID, teeName: String, teeHoles: [Int: CachedCourseTeeHole])] {
        var seen = Set<UUID>()
        var result: [(UUID, String, [Int: CachedCourseTeeHole])] = []
        for p in players {
            guard let id = p.teeId, let name = p.teeName, let holes = p.teeHoles else { continue }
            if seen.insert(id).inserted {
                result.append((id, name, holes))
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                VStack(spacing: 0) {
                    if isMultiplayer { multiHeaderRow } else { headerRow }
                    Divider()
                    if isMultiplayer { multiFront9 } else { front9Section }
                    if isMultiplayer {
                        multiSubtotalRow(label: "OUT", holes: holesIn(1...9))
                    } else {
                        subtotalRow(label: "OUT", holes: holesIn(1...9))
                    }
                    Divider().frame(height: 2).background(Color.secondary)
                    if isMultiplayer { multiBack9 } else { back9Section }
                    if isMultiplayer {
                        multiSubtotalRow(label: "IN", holes: holesIn(10...18))
                    } else {
                        subtotalRow(label: "IN", holes: holesIn(10...18))
                    }
                    Divider().frame(height: 2).background(Color.secondary)
                    if isMultiplayer {
                        multiSubtotalRow(label: "TOT", holes: holesSorted, isTotal: true)
                    } else {
                        subtotalRow(label: "TOT", holes: holesSorted, isTotal: true)
                    }
                }
                .padding(.horizontal, 4)
            }
            .navigationTitle(round.courseName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 0) {
            cell("H", weight: .semibold).frame(width: cellWidth(.hole))
            cell("P", weight: .semibold).frame(width: cellWidth(.par))
            if showsYardage {
                cell("Y", weight: .semibold).frame(width: cellWidth(.yardage))
            }
            cell("S", weight: .semibold, alignment: .trailing).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12))
    }

    @ViewBuilder
    private var front9Section: some View {
        ForEach(holesIn(1...9), id: \.id) { hole in
            holeRow(hole)
            Divider().opacity(0.4)
        }
    }

    @ViewBuilder
    private var back9Section: some View {
        ForEach(holesIn(10...18), id: \.id) { hole in
            holeRow(hole)
            Divider().opacity(0.4)
        }
    }

    @ViewBuilder
    private func holeRow(_ hole: Hole) -> some View {
        // Penalty strokes count toward the score (one penalty = +1).
        let strokeCount = round.strokes.filter { $0.holeNumber == hole.number }.count
        let par = teeHoles?[hole.number]?.par ?? hole.par
        let yardage = teeHoles?[hole.number]?.yardage
        let isCompleted = round.isHoleCompleted(hole.number)
        let isCurrent = hole.number == (round.currentHoleIndex + 1)

        HStack(spacing: 0) {
            cell("\(hole.number)").frame(width: cellWidth(.hole))
                .background(isCurrent ? Color.accentColor.opacity(0.2) : Color.clear)
            cell(par.map { "\($0)" } ?? "—").frame(width: cellWidth(.par))
            if showsYardage {
                cell(yardage.map { "\($0)" } ?? "—").frame(width: cellWidth(.yardage))
            }
            scoreCell(strokes: strokeCount, par: par, isCompleted: isCompleted)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .opacity((isCompleted || isCurrent) ? 1.0 : 0.55)
    }

    @ViewBuilder
    private func subtotalRow(label: String, holes: [Hole], isTotal: Bool = false) -> some View {
        let parTotal = holes.compactMap { teeHoles?[$0.number]?.par ?? $0.par }.reduce(0, +)
        let yardTotal = showsYardage
            ? holes.compactMap { teeHoles?[$0.number]?.yardage }.reduce(0, +)
            : 0
        let strokeTotal = round.strokes
            .filter { s in holes.contains(where: { $0.number == s.holeNumber }) }
            .count

        HStack(spacing: 0) {
            cell(label, weight: .bold).frame(width: cellWidth(.hole))
            cell("\(parTotal)", weight: .bold).frame(width: cellWidth(.par))
            if showsYardage {
                cell("\(yardTotal)", weight: .bold).frame(width: cellWidth(.yardage))
            }
            cell("\(strokeTotal)", weight: .bold, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .background(isTotal ? Color.secondary.opacity(0.18) : Color.secondary.opacity(0.08))
    }

    @ViewBuilder
    private func scoreCell(strokes: Int, par: Int?, isCompleted: Bool) -> some View {
        HStack(spacing: 6) {
            if isCompleted, let par = par, strokes > 0 {
                let diff = strokes - par
                if diff != 0 {
                    Text(diff > 0 ? "+\(diff)" : "\(diff)")
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(diff < 0 ? .green : .red)
                }
            }
            Text(strokes > 0 ? "\(strokes)" : "—")
                .font(.body).fontWeight(strokes > 0 ? .semibold : .regular)
                .foregroundStyle(scoreColor(strokes: strokes, par: par, isCompleted: isCompleted))
        }
        .padding(.trailing, 8)
    }

    private func scoreColor(strokes: Int, par: Int?, isCompleted: Bool) -> Color {
        guard isCompleted, let par = par, strokes > 0 else { return .primary }
        let diff = strokes - par
        if diff < 0 { return .green }
        if diff > 0 { return .red }
        return .primary
    }

    private func holesIn(_ range: ClosedRange<Int>) -> [Hole] {
        holesSorted.filter { range.contains($0.number) }
    }

    @ViewBuilder
    private func cell(_ text: String, weight: Font.Weight = .regular, alignment: Alignment = .center) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(weight)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: alignment)
            .padding(.horizontal, 4)
    }

    // MARK: - Multiplayer rendering

    @ViewBuilder
    private var multiHeaderRow: some View {
        HStack(spacing: 0) {
            cell("H", weight: .semibold).frame(width: cellWidth(.hole))
            cell("P", weight: .semibold).frame(width: cellWidth(.par))
            // Per-tee yardage columns — placeholder "Y" header for now.
            // Distinguishing tees here will land with the multiplayer
            // scorecard polish pass (see docs/MULTIPLAYER.md).
            ForEach(distinctTees, id: \.teeId) { _ in
                cell("Y", weight: .semibold).frame(width: cellWidth(.yardage))
            }
            ForEach(players) { p in
                playerHeaderCell(p).frame(width: cellWidth(.score))
            }
        }
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12))
    }

    @ViewBuilder
    private func playerHeaderCell(_ p: PlaygroupChannel.ScorecardPlayer) -> some View {
        VStack(spacing: 2) {
            Circle()
                .fill(Color(hex: p.colorHex))
                .frame(width: 8, height: 8)
            Text(firstWord(p.displayName))
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    @ViewBuilder
    private var multiFront9: some View {
        ForEach(holesIn(1...9), id: \.id) { hole in
            multiHoleRow(hole)
            Divider().opacity(0.4)
        }
    }

    @ViewBuilder
    private var multiBack9: some View {
        ForEach(holesIn(10...18), id: \.id) { hole in
            multiHoleRow(hole)
            Divider().opacity(0.4)
        }
    }

    @ViewBuilder
    private func multiHoleRow(_ hole: Hole) -> some View {
        // Par defaults to the local round's hole.par; tee-specific par
        // appears alongside the tee yardage column anyway.
        let par = teeHoles?[hole.number]?.par ?? hole.par
        let isCurrent = hole.number == (round.currentHoleIndex + 1)

        HStack(spacing: 0) {
            cell("\(hole.number)").frame(width: cellWidth(.hole))
                .background(isCurrent ? Color.accentColor.opacity(0.2) : Color.clear)
            cell(par.map { "\($0)" } ?? "—").frame(width: cellWidth(.par))
            ForEach(distinctTees, id: \.teeId) { tee in
                cell(tee.teeHoles[hole.number]?.yardage.map { "\($0)" } ?? "—")
                    .frame(width: cellWidth(.yardage))
            }
            ForEach(players) { p in
                playerScoreCell(player: p, hole: hole.number).frame(width: cellWidth(.score))
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func playerScoreCell(player: PlaygroupChannel.ScorecardPlayer, hole: Int) -> some View {
        let count = player.strokesByHole[hole] ?? 0
        let completed = player.completedHoles.contains(hole)
        let par = player.teeHoles?[hole]?.par
        let color: Color = {
            guard completed, let par = par, count > 0 else { return .primary }
            let diff = count - par
            if diff < 0 { return .green }
            if diff > 0 { return .red }
            return .primary
        }()
        Text(count > 0 ? "\(count)" : "—")
            .font(.body)
            .fontWeight(count > 0 ? .semibold : .regular)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func multiSubtotalRow(label: String, holes: [Hole], isTotal: Bool = false) -> some View {
        let parTotal = holes.compactMap { teeHoles?[$0.number]?.par ?? $0.par }.reduce(0, +)
        HStack(spacing: 0) {
            cell(label, weight: .bold).frame(width: cellWidth(.hole))
            cell("\(parTotal)", weight: .bold).frame(width: cellWidth(.par))
            ForEach(distinctTees, id: \.teeId) { tee in
                let yards = holes.compactMap { tee.teeHoles[$0.number]?.yardage }.reduce(0, +)
                cell("\(yards)", weight: .bold).frame(width: cellWidth(.yardage))
            }
            ForEach(players) { p in
                let total = holes.reduce(0) { $0 + (p.strokesByHole[$1.number] ?? 0) }
                cell(total > 0 ? "\(total)" : "—", weight: .bold)
                    .frame(width: cellWidth(.score))
            }
        }
        .padding(.vertical, 4)
        .background(isTotal ? Color.secondary.opacity(0.18) : Color.secondary.opacity(0.08))
    }

    private func firstWord(_ s: String) -> String {
        s.split(separator: " ").first.map(String.init) ?? s
    }

    private enum Column { case hole, par, yardage, score }

    private func cellWidth(_ column: Column) -> CGFloat {
        // Phone has more room than watch — slightly wider columns. SwiftUI
        // calls layout once per width; these are approximate target widths.
        #if os(watchOS)
        switch column {
        case .hole: return 24
        case .par: return 22
        // Yardage holds 3-digit hole yardages (~"367") and 4-digit
        // front/back subtotals (~"3300"); needs more room than the
        // single-letter columns.
        case .yardage: return 44
        case .score: return 32
        }
        #else
        switch column {
        case .hole: return 50
        case .par: return 50
        case .yardage: return 70
        case .score: return 60
        }
        #endif
    }
}
