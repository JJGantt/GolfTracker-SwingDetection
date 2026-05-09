import SwiftUI

struct WatchHomeView: View {
    @StateObject private var store = WatchDataStore.shared
    @StateObject private var connectivity = WatchConnectivityManager.shared
    @State private var navigateToActiveRound = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 5) {
                // App icon and title
                Image(systemName: "figure.golf")
                    .font(.system(size: 40))
                    .foregroundColor(.green)

                HealthKitBanner()

                Spacer()

                // Main action button
                if store.availableClubs.isEmpty {
                    // No clubs synced yet - show waiting state
                    VStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Waiting for clubs to sync...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Open iPhone app")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.gray.opacity(0.3))
                    .cornerRadius(10)
                } else if store.currentRound != nil {
                    // Active round exists - show Continue button
                    NavigationLink(destination: ActiveRoundView()) {
                        Label("Continue Round", systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }


                Button(action: {
                    store.startRoundAtCurrentLocation()
                }) {
                    Label("New Round", systemImage: "flag.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(store.roundStartStatus != nil)

                // Resolver status while a round-start is in flight.
                if let status = store.roundStartStatus {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text(status)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.top, 4)
                }

                Spacer()

                // Connection status indicator
                if connectivity.isActivated {
                    if connectivity.isReachable {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                            Text("iPhone Connected")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                            Text("iPhone Not Reachable")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding()
            .onAppear {
                // Catch any clubs/types/sets edited on the iPhone since we
                // last had a round open. RealtimeSync is round-scoped so it
                // wouldn't have streamed those edits to us in the meantime.
                store.hydrateClubsFromSupabase()
                // Same gap for rounds: solo rounds never open Realtime on
                // watchOS, so iPhone-side mutations to a round in progress
                // (stroke edits, hole tweaks, current-hole advance) are
                // invisible until we pull. One-shot HTTP fetch — no live
                // socket — so the watchOS-WS reliability concern doesn't
                // apply.
                Task { await RealtimeSync.shared.reconcileRoundsWithSupabase() }
            }
            .navigationDestination(isPresented: $navigateToActiveRound) {
                ActiveRoundView()
            }
            // Resolver succeeded → navigate. Watching for currentRound flip to non-nil
            // when no round was active when the user tapped the button.
            .onChange(of: store.currentRound?.id) { _, newId in
                if newId != nil && store.roundStartStatus == nil {
                    navigateToActiveRound = true
                }
            }
            .sheet(item: Binding(
                get: { store.pendingCoursePicker.map { CourseCandidatesWrapper(candidates: $0) } },
                set: { _ in store.pickCourseCandidate(nil) }
            )) { wrapper in
                CoursePickerView(candidates: wrapper.candidates) { picked in
                    store.pickCourseCandidate(picked)
                }
            }
            .sheet(item: Binding(
                get: { store.pendingTeePicker.map { TeePickerWrapper(picker: $0) } },
                set: { _ in /* sheet only dismisses via picking a tee — no skip */ }
            )) { wrapper in
                TeePickerView(
                    courseName: wrapper.picker.courseName,
                    tees: wrapper.picker.tees
                ) { picked in
                    store.pickTee(picked)
                }
                .interactiveDismissDisabled(true)
            }
            .sheet(item: Binding(
                get: { store.pendingScorecardPicker.map { ScorecardPickerWrapper(picker: $0) } },
                set: { _ in /* dismiss only by picking — including "Course not listed" */ }
            )) { wrapper in
                ScorecardPickerView(
                    originalName: wrapper.picker.originalName,
                    candidates: wrapper.picker.candidates
                ) { picked in
                    store.pickScorecardCandidate(picked)
                }
                .interactiveDismissDisabled(true)
            }
        }
    }
}

private struct TeePickerWrapper: Identifiable {
    let picker: WatchDataStore.PendingTeePicker
    var id: String { picker.tees.map { $0.id.uuidString }.joined(separator: "|") }
}

private struct TeePickerView: View {
    let courseName: String
    let tees: [CachedCourseTee]
    let onPick: (CachedCourseTee?) -> Void

    /// Sort: men's tees first, then by total yardage descending (longest tees
    /// first feels natural — most golfers know roughly which one fits them
    /// from longest to shortest).
    private var sorted: [CachedCourseTee] {
        tees.sorted {
            let aGenderRank = $0.gender == "male" ? 0 : 1
            let bGenderRank = $1.gender == "male" ? 0 : 1
            if aGenderRank != bGenderRank { return aGenderRank < bGenderRank }
            return ($0.totalYards ?? 0) > ($1.totalYards ?? 0)
        }
    }

    var body: some View {
        NavigationStack {
            List(sorted) { tee in
                Button { onPick(tee) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(tee.teeName).font(.body)
                            if let gender = tee.gender {
                                Text("(\(gender == "male" ? "M" : "F"))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if let yds = tee.totalYards {
                                Text("\(yds) yd").font(.caption).foregroundColor(.secondary)
                            }
                        }
                        HStack(spacing: 6) {
                            if let par = tee.parTotal {
                                Text("Par \(par)").font(.caption2).foregroundColor(.secondary)
                            }
                            if let rating = tee.courseRating, let slope = tee.slopeRating {
                                Text("• \(rating, specifier: "%.1f")/\(slope)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Pick tee")
        }
    }
}

// Identifiable wrapper so we can drive a `.sheet(item:)` off the candidates array.
private struct CourseCandidatesWrapper: Identifiable {
    let candidates: [RoundResolver.CourseCandidate]
    var id: String { candidates.map(\.name).joined(separator: "|") }
}

private struct CoursePickerView: View {
    let candidates: [RoundResolver.CourseCandidate]
    let onPick: (RoundResolver.CourseCandidate?) -> Void

    private var realCandidates: [RoundResolver.CourseCandidate] {
        candidates.filter {
            if case .manual = $0.source { return false }
            return true
        }
    }
    private var manualCandidate: RoundResolver.CourseCandidate? {
        candidates.first {
            if case .manual = $0.source { return true }
            return false
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pick course")
                    .font(.headline)
                    .padding(.horizontal)
                List {
                    ForEach(realCandidates, id: \.self) { c in
                        Button { onPick(c) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).font(.body)
                                Text("\(Int(c.distanceMeters)) m")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    if let manual = manualCandidate {
                        Section {
                            Button { onPick(manual) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(manual.name).font(.body)
                                    Text("Start a round here anyway.")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onPick(nil) }
                }
            }
        }
    }
}

private struct ScorecardPickerWrapper: Identifiable {
    let picker: WatchDataStore.PendingScorecardPicker
    var id: String { picker.candidates.map { String($0.course.id) }.joined(separator: "|") + "|" + picker.originalName }
}

private struct ScorecardPickerView: View {
    let originalName: String
    let candidates: [RoundResolver.ScorecardCandidate]
    let onPick: (GCAPICourse?) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pick scorecard")
                    .font(.headline)
                    .padding(.horizontal)
                Text(originalName)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                List {
                    ForEach(candidates, id: \.self) { c in
                        Button { onPick(c.course) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.course.club_name ?? c.course.course_name ?? "Unnamed")
                                    .font(.body)
                                    .lineLimit(2)
                                // Show course_name as a secondary line when
                                // it differs from club_name — multi-course
                                // resorts (Stonegate at Solivita: Oaks /
                                // Cypress) share a club_name and would look
                                // identical otherwise.
                                if let course = c.course.course_name,
                                   let club = c.course.club_name,
                                   course != club, !course.isEmpty {
                                    Text(course).font(.caption).foregroundColor(.secondary)
                                }
                                if let loc = c.course.location {
                                    let locStr = [loc.city, loc.state].compactMap { $0 }.joined(separator: ", ")
                                    if !locStr.isEmpty {
                                        Text(locStr).font(.caption2).foregroundColor(.secondary)
                                    }
                                }
                                let m = c.course.tees?.male?.count ?? 0
                                let f = c.course.tees?.female?.count ?? 0
                                if m + f == 0 {
                                    Text("no scorecard data")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                    }
                    Section {
                        Button(role: .destructive) {
                            onPick(nil)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Course not listed").font(.body)
                                Text("Skip scorecard.")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    WatchHomeView()
}
