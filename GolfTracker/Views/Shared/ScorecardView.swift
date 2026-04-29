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

    private var holesSorted: [Hole] {
        round.holes.sorted { $0.number < $1.number }
    }

    private var showsYardage: Bool { teeHoles != nil && teeName != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    headerRow
                    Divider()
                    front9Section
                    subtotalRow(label: "OUT", holes: holesIn(1...9))
                    Divider().frame(height: 2).background(Color.secondary)
                    back9Section
                    subtotalRow(label: "IN", holes: holesIn(10...18))
                    Divider().frame(height: 2).background(Color.secondary)
                    subtotalRow(label: "TOT", holes: holesSorted, isTotal: true)
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
            cell("Hole", weight: .semibold).frame(width: cellWidth(.hole))
            cell("Par", weight: .semibold).frame(width: cellWidth(.par))
            if showsYardage, let teeName = teeName {
                cell(teeName, weight: .semibold).frame(width: cellWidth(.yardage))
            }
            cell("Score", weight: .semibold, alignment: .trailing).frame(maxWidth: .infinity, alignment: .trailing)
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
        let strokeCount = round.strokes.filter { $0.holeNumber == hole.number && !$0.isPenalty }.count
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
            .filter { s in holes.contains(where: { $0.number == s.holeNumber }) && !s.isPenalty }
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
            .frame(maxWidth: .infinity, alignment: alignment)
            .padding(.horizontal, 4)
    }

    private enum Column { case hole, par, yardage }

    private func cellWidth(_ column: Column) -> CGFloat {
        // Phone has more room than watch — slightly wider columns. SwiftUI
        // calls layout once per width; these are approximate target widths.
        #if os(watchOS)
        switch column {
        case .hole: return 30
        case .par: return 30
        case .yardage: return 40
        }
        #else
        switch column {
        case .hole: return 50
        case .par: return 50
        case .yardage: return 70
        }
        #endif
    }
}
