import SwiftUI

struct RoundsHistoryView: View {
    @ObservedObject var store: DataStore
    let initialCourseFilter: UUID?
    @State private var selectedCourseFilter: UUID? = nil
    @State private var selectedRound: Round?
    /// Set when the user taps the "Continue Round" pin → drives navigation
    /// to HolePlayView for the currently-in-progress round.
    @State private var continuingRound: Round?

    init(store: DataStore, initialCourseFilter: UUID? = nil) {
        self.store = store
        self.initialCourseFilter = initialCourseFilter
        _selectedCourseFilter = State(initialValue: initialCourseFilter)
    }

    /// Past rounds (excludes the currently-in-progress round, which is
    /// pinned at the top in its own section).
    private var pastRounds: [Round] {
        let current = store.currentRound
        var rounds = store.rounds.sorted { $0.date > $1.date }
        if let current = current {
            rounds.removeAll { $0.id == current.id }
        }
        if let courseId = selectedCourseFilter {
            return rounds.filter { $0.courseId == courseId }
        }
        return rounds
    }

    private var availableCourses: [Course] {
        let courseIds = Set(store.rounds.map { $0.courseId })
        return store.courses.filter { courseIds.contains($0.id) }
    }

    private func course(for round: Round) -> Course? {
        store.courses.first { $0.id == round.courseId }
    }

    var body: some View {
        NavigationStack {
            List {
                if let current = store.currentRound {
                    Section("In Progress") {
                        Button {
                            continuingRound = current
                        } label: {
                            ContinueRoundRow(round: current, store: store)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !availableCourses.isEmpty {
                    Section {
                        Picker("Filter by Course", selection: $selectedCourseFilter) {
                            Text("All Courses").tag(nil as UUID?)
                            ForEach(availableCourses) { course in
                                Text(course.name).tag(course.id as UUID?)
                            }
                        }
                    }
                }

                if pastRounds.isEmpty && store.currentRound == nil {
                    ContentUnavailableView(
                        "No Rounds",
                        systemImage: "figure.golf",
                        description: Text("Play a round to see your history here")
                    )
                } else {
                    Section {
                        ForEach(pastRounds) { round in
                            Button(action: {
                                selectedRound = round
                            }) {
                                RoundRow(round: round, store: store)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        if store.currentRound != nil {
                            Text("Past Rounds")
                        }
                    }
                }
            }
            .navigationTitle("Rounds")
            .navigationDestination(item: $selectedRound) { round in
                RoundDetailView(store: store, round: round)
            }
            .navigationDestination(item: $continuingRound) { round in
                if let c = course(for: round) {
                    HolePlayView(store: store, course: c, resumingRound: round)
                } else {
                    Text("Course data unavailable for this round.")
                        .foregroundColor(.secondary)
                        .padding()
                }
            }
        }
    }
}

/// Pin shown at the top of the Rounds list when a round is currently
/// in progress (cross-device — picks up rounds started on the watch).
private struct ContinueRoundRow: View {
    let round: Round
    @ObservedObject var store: DataStore

    private var totalStrokes: Int { round.strokes.count }
    private var holesPlayed: Int { round.completedHolesArray.count }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.circle.fill")
                .foregroundColor(.green)
                .font(.title)
            VStack(alignment: .leading, spacing: 2) {
                Text("Continue Round")
                    .font(.headline)
                Text(round.courseName)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("\(holesPlayed) of \(round.holes.count) holes • \(totalStrokes) strokes")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct RoundRow: View {
    let round: Round
    @ObservedObject var store: DataStore

    private var course: Course? {
        store.courses.first { $0.id == round.courseId }
    }

    private var totalStrokes: Int {
        round.strokes.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(round.courseName)
                        .font(.headline)
                    Text(round.date.formatted(date: .long, time: .shortened))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(totalStrokes)")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("strokes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
