import SwiftUI

struct RoundsHistoryView: View {
    @ObservedObject var store: DataStore
    let initialCourseFilter: UUID?
    @State private var selectedCourseFilter: UUID? = nil
    @State private var selectedRound: Round?

    init(store: DataStore, initialCourseFilter: UUID? = nil) {
        self.store = store
        self.initialCourseFilter = initialCourseFilter
        _selectedCourseFilter = State(initialValue: initialCourseFilter)
    }

    private var filteredRounds: [Round] {
        let rounds = store.rounds.sorted { $0.date > $1.date }
        if let courseId = selectedCourseFilter {
            return rounds.filter { $0.courseId == courseId }
        }
        return rounds
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

                if filteredRounds.isEmpty {
                    ContentUnavailableView(
                        "No Rounds",
                        systemImage: "figure.golf",
                        description: Text("Play a round to see your history here")
                    )
                } else {
                    ForEach(filteredRounds) { round in
                        Button(action: {
                            selectedRound = round
                        }) {
                            RoundRow(round: round, store: store)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Round History")
            .navigationDestination(item: $selectedRound) { round in
                RoundDetailView(store: store, round: round)
            }
        }
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
