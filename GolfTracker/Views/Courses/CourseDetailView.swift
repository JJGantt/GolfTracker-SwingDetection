import SwiftUI
import MapKit

/// Per-course screen, reached by tapping a course in Stats → By Course.
///
/// Stats-first: how this course has actually played for you, then the holes
/// that cost you strokes, then the rounds themselves. Course management
/// (rename, rating/slope, delete) lives at the bottom — it's the only place in
/// the app that can rename or delete a course, so it can't be dropped.
///
/// The hole-detection dev toggles that used to sit here moved to Settings →
/// Developer (long-press the Settings title). They control the satellite-blob
/// green analyzer and were never course settings.
struct CourseDetailView: View {
    @ObservedObject var store: DataStore
    let course: Course

    @State private var position = MapCameraPosition.automatic
    @State private var showingEditCourseInfo = false
    @State private var showingRoundsHistory = false
    @State private var showingDeleteConfirmation = false
    @State private var showingCannotDeleteAlert = false
    @Environment(\.dismiss) private var dismiss

    private var currentCourse: Course {
        store.courses.first { $0.id == course.id } ?? course
    }

    private var stats: CourseStats? {
        store.playerStats.perCourseStats[currentCourse.id.uuidString]
    }

    private var holesSorted: [Hole] {
        currentCourse.holes.sorted { $0.number < $1.number }
    }

    private var totalPar: Int? {
        let pars = currentCourse.holes.compactMap { $0.par }
        guard pars.count == currentCourse.holes.count, !pars.isEmpty else { return nil }
        return pars.reduce(0, +)
    }

    var body: some View {
        List {
            overviewSection
            scoringSection
            holeBreakdownSection
            roundsSection
            layoutSection
            // A shared (OSM) course is not the user's to rename or delete.
            if !currentCourse.isShared {
                manageSection
            }
        }
        .navigationTitle(currentCourse.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showingRoundsHistory) {
            RoundsHistoryView(store: store, initialCourseFilter: currentCourse.id)
        }
        .sheet(isPresented: $showingEditCourseInfo) {
            EditCourseInfoView(store: store, course: currentCourse)
        }
        .confirmationDialog("Delete Course", isPresented: $showingDeleteConfirmation) {
            Button("Delete \(currentCourse.name)", role: .destructive) {
                store.deleteCourse(currentCourse)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
        .alert("Can't Delete", isPresented: $showingCannotDeleteAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Delete this course's rounds first.")
        }
        .onAppear {
            updateMapPosition()
            if currentCourse.city == nil && !currentCourse.holes.isEmpty {
                store.updateCourseCity(currentCourse)
            }
        }
    }

    // MARK: - Overview

    private var overviewSection: some View {
        Section {
            HStack(spacing: 0) {
                BigStatCell(label: "Rounds", value: "\(stats?.roundsPlayed ?? 0)", unit: nil)
                Divider()
                BigStatCell(label: "Scored", value: "\(stats?.scoredRounds ?? 0)", unit: "9s + 18s")
                Divider()
                BigStatCell(
                    label: "Holes",
                    value: "\(currentCourse.holes.count)",
                    unit: totalPar.map { "par \($0)" }
                )
            }
            .padding(.vertical, 4)
            if let last = stats?.lastPlayed {
                HStack {
                    Text("Last played")
                    Spacer()
                    Text(last.formatted(date: .abbreviated, time: .omitted))
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        }
    }

    // MARK: - Scoring

    private var scoringSection: some View {
        Section("Scoring") {
            if let s = stats, s.scoredRounds > 0 {
                HStack(spacing: 0) {
                    BigStatCell(
                        label: "Avg",
                        value: s.avgScoreVsPar.map { formatScore($0) } ?? "--",
                        unit: "vs par"
                    )
                    Divider()
                    BigStatCell(
                        label: "Best",
                        value: s.bestScoreVsPar.map { formatScore(Double($0)) } ?? "--",
                        unit: "vs par"
                    )
                    Divider()
                    BigStatCell(
                        label: "Worst",
                        value: s.worstScoreVsPar.map { formatScore(Double($0)) } ?? "--",
                        unit: "vs par"
                    )
                }
                .padding(.vertical, 4)
            } else {
                Text("Play a full 9 or 18 here to start scoring.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Hole breakdown

    /// Every hole with history, ordered by number, with a bar showing how far
    /// over par it plays. The point of the screen: which holes cost strokes.
    private var holeBreakdownSection: some View {
        let holeStats = stats?.holeStats ?? [:]
        guard !holeStats.isEmpty else { return AnyView(EmptyView()) }
        let ordered = holeStats.values.sorted { $0.holeNumber < $1.holeNumber }
        let worst = ordered.map(\.avgVsPar).max() ?? 1

        return AnyView(
            Section("By Hole") {
                ForEach(ordered, id: \.holeNumber) { h in
                    HStack(spacing: 10) {
                        Text("\(h.holeNumber)")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .frame(width: 22, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        Text("Par \(h.par)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .leading)

                        GeometryReader { geo in
                            let frac = worst > 0 ? max(0, h.avgVsPar) / worst : 0
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.gray.opacity(0.15))
                                Capsule()
                                    .fill(h.avgVsPar > 0 ? Color.orange : Color.green)
                                    .frame(width: max(3, geo.size.width * frac))
                            }
                            .frame(height: 6)
                            .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: 18)

                        Text(formatScore(h.avgVsPar))
                            .font(.caption)
                            .fontWeight(.medium)
                            .frame(width: 30, alignment: .trailing)
                        Text(String(format: "%.1f putts", h.avgPutts))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 62, alignment: .trailing)
                    }
                }
            }
        )
    }

    // MARK: - Rounds

    private var roundsSection: some View {
        Section {
            Button {
                showingRoundsHistory = true
            } label: {
                HStack {
                    Label("Rounds here", systemImage: "clock.arrow.circlepath")
                    Spacer()
                    Text("\(stats?.roundsPlayed ?? 0)")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .disabled(!store.hasRounds(for: currentCourse))
        }
    }

    // MARK: - Layout

    private var layoutSection: some View {
        let holesWithCoords = currentCourse.holes.filter { $0.hasLocation }
        guard !holesWithCoords.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            Section("Layout") {
                Map(position: $position) {
                    ForEach(holesWithCoords) { hole in
                        if let coord = hole.coordinate {
                            Annotation("", coordinate: coord) {
                                ZStack {
                                    Circle().fill(.red).frame(width: 22, height: 22)
                                    Text("\(hole.number)")
                                        .font(.caption2)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                }
                            }
                        }
                    }
                }
                .frame(height: 220)
                .listRowInsets(EdgeInsets())
            }
        )
    }

    // MARK: - Manage

    private var manageSection: some View {
        Section {
            Button {
                showingEditCourseInfo = true
            } label: {
                Label("Edit Course Info", systemImage: "pencil")
            }
            Button(role: .destructive) {
                if store.hasRounds(for: currentCourse) {
                    showingCannotDeleteAlert = true
                } else {
                    showingDeleteConfirmation = true
                }
            } label: {
                Label("Delete Course", systemImage: "trash")
            }
        }
    }

    // MARK: - Helpers

    private func formatScore(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded > 0 { return "+\(String(format: "%.1f", rounded))" }
        if rounded < 0 { return String(format: "%.1f", rounded) }
        return "E"
    }

    private func updateMapPosition() {
        let coordinates = currentCourse.holes.compactMap { $0.coordinate }
        guard !coordinates.isEmpty else { return }
        let minLat = coordinates.map(\.latitude).min() ?? 0
        let maxLat = coordinates.map(\.latitude).max() ?? 0
        let minLon = coordinates.map(\.longitude).min() ?? 0
        let maxLon = coordinates.map(\.longitude).max() ?? 0
        position = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                          longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.3, 0.01),
                                   longitudeDelta: max((maxLon - minLon) * 1.3, 0.01))
        ))
    }
}

struct InfoBox: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }
}

struct EditCourseInfoView: View {
    @ObservedObject var store: DataStore
    let course: Course
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var ratingText: String
    @State private var slopeText: String

    init(store: DataStore, course: Course) {
        self.store = store
        self.course = course
        _name = State(initialValue: course.name)
        _ratingText = State(initialValue: course.rating != nil ? String(format: "%.1f", course.rating!) : "")
        _slopeText = State(initialValue: course.slope != nil ? "\(course.slope!)" : "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Course Information") {
                    TextField("Course Name", text: $name)

                    TextField("Rating (e.g. 72.5)", text: $ratingText)
                        .keyboardType(.decimalPad)

                    TextField("Slope (e.g. 130)", text: $slopeText)
                        .keyboardType(.numberPad)
                }
            }
            .navigationTitle("Edit Course Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let rating = Double(ratingText)
                        let slope = Int(slopeText)
                        store.updateCourseInfo(course, name: name, rating: rating, slope: slope)
                        dismiss()
                    }
                }
            }
        }
    }
}
