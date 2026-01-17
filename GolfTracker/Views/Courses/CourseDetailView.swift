import SwiftUI
import MapKit

struct CourseDetailView: View {
    @ObservedObject var store: DataStore
    let course: Course

    @State private var position = MapCameraPosition.automatic
    @State private var showingPlay = false
    @State private var showingEditCourseInfo = false
    @State private var showingRoundsHistory = false
    @State private var showingDeleteConfirmation = false
    @State private var showingCannotDeleteAlert = false
    @Environment(\.dismiss) private var dismiss

    private var currentCourse: Course {
        store.courses.first { $0.id == course.id } ?? course
    }

    private var totalPar: Int? {
        let pars = currentCourse.holes.compactMap { $0.par }
        if pars.count == currentCourse.holes.count && !pars.isEmpty {
            return pars.reduce(0, +)
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Map showing all holes with coordinates
                let holesWithCoords = currentCourse.holes.filter { $0.hasLocation }
                if !holesWithCoords.isEmpty {
                    Map(position: $position) {
                        ForEach(holesWithCoords) { hole in
                            if let coord = hole.coordinate {
                                Annotation("", coordinate: coord) {
                                    ZStack {
                                        Circle()
                                            .fill(.red)
                                            .frame(width: 25, height: 25)
                                        Text("\(hole.number)")
                                            .font(.caption2)
                                            .fontWeight(.bold)
                                            .foregroundColor(.white)
                                    }
                                }
                            }
                        }
                    }
                    .frame(height: 300)
                    .cornerRadius(12)
                    .padding(.horizontal)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "map")
                            .font(.system(size: 50))
                            .foregroundColor(.secondary)
                        Text("No holes added yet")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    .frame(height: 300)
                    .frame(maxWidth: .infinity)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)
                    .padding(.horizontal)
                }

                // Course city
                if let city = currentCourse.city {
                    Text(city)
                        .font(.title3)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }

                // Course info
                HStack(spacing: 12) {
                    InfoBox(title: "Holes", value: "\(currentCourse.holes.count)")

                    if let par = totalPar {
                        InfoBox(title: "Par", value: "\(par)")
                    }

                    if let rating = currentCourse.rating {
                        InfoBox(title: "Rating", value: String(format: "%.1f", rating))
                    }

                    if let slope = currentCourse.slope {
                        InfoBox(title: "Slope", value: "\(slope)")
                    }
                }
                .padding(.horizontal)

                // Action buttons
                VStack(spacing: 12) {
                    Button(action: {
                        showingPlay = true
                    }) {
                        Label("Play Round", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

                    Button(action: {
                        showingEditCourseInfo = true
                    }) {
                        Label("Edit Course Info", systemImage: "info.circle")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.bordered)

                    Button(action: {
                        showingRoundsHistory = true
                    }) {
                        Label("View Rounds", systemImage: "clock.fill")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!store.hasRounds(for: currentCourse))

                    Button(action: {
                        if store.hasRounds(for: currentCourse) {
                            showingCannotDeleteAlert = true
                        } else {
                            showingDeleteConfirmation = true
                        }
                    }) {
                        Label("Delete Course", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .navigationTitle(currentCourse.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showingPlay) {
            HolePlayView(store: store, course: currentCourse)
        }
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
            Text("Are you sure you want to delete this course? This action cannot be undone.")
        }
        .alert("Cannot Delete Course", isPresented: $showingCannotDeleteAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This course has rounds recorded. Please delete all rounds for this course before deleting the course.")
        }
        .onAppear {
            updateMapPosition()
            if currentCourse.city == nil && !currentCourse.holes.isEmpty {
                store.updateCourseCity(currentCourse)
            }
        }
    }

    private func updateMapPosition() {
        // Only consider holes with coordinates
        let coordinates = currentCourse.holes.compactMap { $0.coordinate }
        guard !coordinates.isEmpty else { return }

        // Calculate region that fits all holes
        let minLat = coordinates.map { $0.latitude }.min() ?? 0
        let maxLat = coordinates.map { $0.latitude }.max() ?? 0
        let minLon = coordinates.map { $0.longitude }.min() ?? 0
        let maxLon = coordinates.map { $0.longitude }.max() ?? 0

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.3, 0.01),
            longitudeDelta: max((maxLon - minLon) * 1.3, 0.01)
        )

        position = .region(MKCoordinateRegion(center: center, span: span))
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

