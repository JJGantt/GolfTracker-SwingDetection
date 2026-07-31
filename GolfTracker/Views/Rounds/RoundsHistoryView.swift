import SwiftUI

struct RoundsHistoryView: View {
    @ObservedObject var store: DataStore
    let initialCourseFilter: UUID?
    @State private var selectedCourseFilter: UUID? = nil
    @State private var selectedRound: Round?
    @State private var pendingDelete: Round?

    init(store: DataStore, initialCourseFilter: UUID? = nil) {
        self.store = store
        self.initialCourseFilter = initialCourseFilter
        _selectedCourseFilter = State(initialValue: initialCourseFilter)
    }

    private var displayedRounds: [Round] {
        let sorted = store.rounds.sorted { $0.date > $1.date }
        guard let courseId = selectedCourseFilter else { return sorted }
        return sorted.filter { $0.courseId == courseId }
    }

    private var availableCourses: [Course] {
        let courseIds = Set(store.rounds.map { $0.courseId })
        return store.courses.filter { courseIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
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

                if displayedRounds.isEmpty {
                    ContentUnavailableView(
                        "No Rounds",
                        systemImage: "figure.golf",
                        description: Text("Play a round to see your history here")
                    )
                } else {
                    Section {
                        ForEach(displayedRounds) { round in
                            Button(action: { selectedRound = round }) {
                                RoundRow(round: round, store: store)
                            }
                            .buttonStyle(.plain)
                            // History lists every round, partials included, so
                            // this is where abandoned starts get cleaned up.
                            // Deleting used to mean opening each round first.
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    pendingDelete = round
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .navigationDestination(item: $selectedRound) { round in
                RoundDetailView(store: store, round: round)
            }
            .confirmationDialog(
                "Delete Round",
                isPresented: Binding(get: { pendingDelete != nil },
                                     set: { if !$0 { pendingDelete = nil } }),
                presenting: pendingDelete
            ) { round in
                Button("Delete", role: .destructive) {
                    store.deleteRound(round)
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { round in
                Text("\(round.courseName) · \(round.date.formatted(date: .abbreviated, time: .shortened))")
            }
        }
    }
}

struct RoundRow: View {
    let round: Round
    @ObservedObject var store: DataStore

    private var totalStrokes: Int { round.strokes.count }
    /// Holes with any stroke on them. Shown so a partial round is obvious in
    /// the list without opening it — History carries every round, including
    /// abandoned starts, and this is where they get found and cleaned up.
    private var holesPlayed: Int { Set(round.strokes.map(\.holeNumber)).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(round.courseName)
                            .font(.headline)
                        if round.endedAt == nil {
                            Text("In Progress")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green)
                                .cornerRadius(4)
                        }
                    }
                    Text(round.date.formatted(date: .long, time: .shortened))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(holesPlayed == 0
                         ? "No shots recorded"
                         : "\(holesPlayed) hole\(holesPlayed == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundColor(holesPlayed == 0 ? .orange : .secondary)
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
