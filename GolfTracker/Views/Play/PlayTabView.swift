import SwiftUI
import CoreLocation

/// The Play tab. Shows HolePlayView directly when a round is active (tab bar
/// stays visible — no navigation push). When no round is active, shows a
/// GPS-based round-start screen.
struct PlayTabView: View {
    @EnvironmentObject var store: DataStore

    var body: some View {
        if let round = store.currentRound,
           let course = store.courses.first(where: { $0.id == round.courseId }) {
            NavigationStack {
                HolePlayView(store: store, course: course, resumingRound: round)
            }
        } else {
            StartRoundView()
        }
    }
}

// MARK: - StartRoundView

private struct StartRoundView: View {
    @EnvironmentObject var store: DataStore

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                // Location-denied banner. Lives here because this is the
                // screen that can't work without location — Start Round reads
                // GPS immediately. It used to be mounted on HomeView, which
                // was removed when the tab bar became Stats/Play/History/
                // Settings, leaving the denied state with no guidance at all:
                // Start Round just fell through to the name prompt.
                LocationPermissionBanner()
                    .padding(.horizontal, 20)

                Image(systemName: "figure.golf")
                    .font(.system(size: 64))
                    .foregroundColor(.green)

                VStack(spacing: 8) {
                    Text("Ready to Play?")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("StrokeSaver will find your course using GPS.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Button(action: { store.startRoundAtCurrentLocation() }) {
                    if store.roundStartStatus != nil {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(.white)
                            Text(store.roundStartStatus ?? "Finding course…")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    } else {
                        Label("Start Round", systemImage: "location.fill")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(store.roundStartStatus != nil)
                .padding(.horizontal, 32)

                Spacer()
            }
            .navigationTitle("Play")
            .navigationBarTitleDisplayMode(.inline)
            // Pull the last 8h of rounds on appear so a round started on the
            // watch shows up here without the user having to background the
            // app. Realtime normally delivers it, but postgres-changes don't
            // replay across a dropped socket and the only other catch-up was
            // the scenePhase→active hook — which never fires if the phone was
            // already open when the watch started the round.
            .task { await RealtimeSync.shared.reconcileRoundsWithSupabase() }
            .refreshable { await RealtimeSync.shared.reconcileRoundsWithSupabase() }
        }
        // Course picker — shown when GPS finds multiple candidates
        .sheet(item: Binding(
            get: { store.pendingCoursePicker.map { CourseCandidatesWrapper(candidates: $0) } },
            set: { if $0 == nil { store.pickCourseCandidate(nil) } }
        )) { wrapper in
            IOSCoursePickerView(candidates: wrapper.candidates) { picked in
                store.pickCourseCandidate(picked)
            }
        }
        // Scorecard picker — pick which GolfCourseAPI entry matches
        .sheet(item: Binding(
            get: { store.pendingScorecardPicker },
            set: { if $0 == nil { store.pickScorecardCandidate(nil) } }
        )) { pending in
            IOSScorecardPickerView(
                originalName: pending.originalName,
                candidates: pending.candidates
            ) { picked in
                store.pickScorecardCandidate(picked)
            }
            .interactiveDismissDisabled(true)
        }
        // Tee picker
        .sheet(item: Binding(
            get: { store.pendingTeePicker },
            set: { if $0 == nil { store.pickTee(nil) } }
        )) { pending in
            IOSTeePickerView(
                courseName: pending.courseName,
                tees: pending.tees
            ) { picked in
                store.pickTee(picked)
            }
            .interactiveDismissDisabled(true)
        }
        // Name-this-course prompt — nothing identified where the user is.
        .sheet(isPresented: $store.pendingCourseNamePrompt) {
            IOSCourseNamePromptView { name in
                store.submitCourseName(name)
            }
            .interactiveDismissDisabled(true)
        }
    }
}

// MARK: - Name this course

/// Shown when nothing identified where the user is. Naming it once stores the
/// course at their GPS, so the next round here matches by proximity and comes
/// back under the same name instead of creating another anonymous entry.
private struct IOSCourseNamePromptView: View {
    let onSubmit: (String?) -> Void
    @State private var name: String = ""
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Course name", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($focused)
                        .onSubmit { if !trimmed.isEmpty { onSubmit(trimmed) } }
                } header: {
                    Text("Name this course")
                } footer: {
                    Text("We'll remember it for next time you play here.")
                }
            }
            .navigationTitle("New Course")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onSubmit(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { onSubmit(trimmed) }
                        .disabled(trimmed.isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }
}

// MARK: - Course picker

private struct CourseCandidatesWrapper: Identifiable {
    let candidates: [RoundResolver.CourseCandidate]
    var id: String { candidates.map { $0.name }.joined(separator: "|") }
}

private struct IOSCoursePickerView: View {
    let candidates: [RoundResolver.CourseCandidate]
    let onPick: (RoundResolver.CourseCandidate?) -> Void

    var body: some View {
        NavigationStack {
            List(candidates, id: \.self) { candidate in
                Button(action: { onPick(candidate) }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidate.name)
                            .font(.body)
                            .foregroundColor(.primary)
                        Text(String(format: "%.0f yd away", candidate.distanceMeters * 1.09361))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Select Course")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onPick(nil) }
                }
            }
        }
    }
}

// MARK: - Scorecard picker

private struct IOSScorecardPickerView: View {
    let originalName: String
    let candidates: [RoundResolver.ScorecardCandidate]
    let onPick: (GCAPICourse?) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(candidates, id: \.course.id) { candidate in
                        Button(action: { onPick(candidate.course) }) {
                            Text(candidate.course.displayName)
                                .font(.body)
                                .foregroundColor(.primary)
                                .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("Matches for \"\(originalName)\"")
                }

                Section {
                    Button(action: { onPick(nil) }) {
                        Text("Course not listed")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Select Scorecard")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Tee picker

private struct IOSTeePickerView: View {
    let courseName: String
    let tees: [CachedCourseTee]
    let onPick: (CachedCourseTee?) -> Void

    var sortedTees: [CachedCourseTee] {
        tees.sorted {
            if $0.gender != $1.gender {
                return ($0.gender ?? "") < ($1.gender ?? "")
            }
            return ($0.totalYards ?? 0) > ($1.totalYards ?? 0)
        }
    }

    var body: some View {
        NavigationStack {
            List(sortedTees, id: \.id) { tee in
                Button(action: { onPick(tee) }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tee.teeName)
                                .font(.body)
                                .foregroundColor(.primary)
                            if let yards = tee.totalYards {
                                Text("\(yards) yards")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        if let par = tee.parTotal {
                            Text("Par \(par)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(courseName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { onPick(nil) }
                }
            }
        }
    }
}
