import SwiftUI
import MapKit

struct CourseEditorView: View {
    @ObservedObject var store: DataStore
    let course: Course

    @StateObject private var locationManager = LocationManager()
    @State private var position = MapCameraPosition.automatic
    @State private var selectedHole: Hole?
    @State private var showingHoleActions = false
    @State private var showingRenumberAlert = false
    @State private var newHoleNumber = ""
    @State private var showingOverviewMap = false
    @State private var useStandardMap = false

    private var currentCourse: Course {
        store.courses.first { $0.id == course.id } ?? course
    }

    private var nearestHole: Hole? {
        guard let userLocation = locationManager.location else { return nil }
        guard !currentCourse.holes.isEmpty else { return nil }

        return currentCourse.holes.min { hole1, hole2 in
            let loc1 = CLLocation(latitude: hole1.latitude, longitude: hole1.longitude)
            let loc2 = CLLocation(latitude: hole2.latitude, longitude: hole2.longitude)
            return userLocation.distance(from: loc1) < userLocation.distance(from: loc2)
        }
    }
    
    var body: some View {
        mapView
        .navigationTitle(currentCourse.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: {
                    showingOverviewMap.toggle()
                    updateMapPosition()
                }) {
                    Image(systemName: showingOverviewMap ? "location.fill" : "globe")
                }
                .disabled(currentCourse.holes.isEmpty)
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    useStandardMap.toggle()
                }) {
                    Image(systemName: useStandardMap ? "map.fill" : "photo.fill")
                }
            }

            ToolbarItemGroup(placement: .bottomBar) {
                Button(action: addHoleAtCurrentLocation) {
                    Label("Add Here", systemImage: "plus.circle.fill")
                }
                .disabled(locationManager.location == nil)

                Spacer()

                Button(action: moveNearestHoleToCurrentLocation) {
                    Label("Move Nearest", systemImage: "location.fill")
                }
                .disabled(nearestHole == nil || locationManager.location == nil)
            }
        }
        .confirmationDialog("Hole \(selectedHole?.number ?? 0)", isPresented: $showingHoleActions) {
            Button("Renumber") {
                if let hole = selectedHole {
                    newHoleNumber = "\(hole.number)"
                    showingRenumberAlert = true
                }
            }

            Button("Delete Hole", role: .destructive) {
                if let hole = selectedHole {
                    store.deleteHole(hole, from: currentCourse)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Renumber Hole", isPresented: $showingRenumberAlert) {
            TextField("Hole number", text: $newHoleNumber)
                .keyboardType(.numberPad)
            Button("Cancel", role: .cancel) {
                newHoleNumber = ""
            }
            Button("Update") {
                if let hole = selectedHole,
                   let number = Int(newHoleNumber),
                   number > 0,
                   number <= currentCourse.holes.count {
                    store.renumberHole(hole, in: currentCourse, newNumber: number)
                }
                newHoleNumber = ""
            }
        } message: {
            Text("Enter new hole number (1-\(currentCourse.holes.count))")
        }
        .onAppear {
            locationManager.requestPermission()
            if let firstHole = currentCourse.holes.first {
                position = .region(MKCoordinateRegion(
                    center: firstHole.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.001, longitudeDelta: 0.001)
                ))
            }
        }
    }

    private var mapView: some View {
        MapReader { proxy in
            Map(position: $position) {
                ForEach(currentCourse.holes) { hole in
                    Annotation("", coordinate: hole.coordinate) {
                        if showingOverviewMap {
                            ZStack {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 25, height: 25)
                                Text("\(hole.number)")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                            }
                        } else {
                            HoleMarker(number: hole.number, isNearest: nearestHole?.id == hole.id)
                                .onTapGesture {
                                    selectedHole = hole
                                    showingHoleActions = true
                                }
                        }
                    }
                }

                // Show user location
                if let userLocation = locationManager.location, !showingOverviewMap {
                    Annotation("", coordinate: userLocation.coordinate) {
                        UserLocationMarker(heading: locationManager.heading)
                    }
                }
            }
            .mapStyle(useStandardMap ? .standard : .hybrid)
            .onTapGesture { screenCoord in
                if !showingOverviewMap {
                    // Only add hole if not tapping near an existing hole
                    if let coordinate = proxy.convert(screenCoord, from: .local),
                       !isTappingNearExistingHole(coordinate: coordinate) {
                        store.addHole(to: currentCourse, coordinate: coordinate, par: nil, userLocation: locationManager.location?.coordinate)
                    }
                }
            }
        }
    }

    private func isTappingNearExistingHole(coordinate: CLLocationCoordinate2D) -> Bool {
        let tappedLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        // Check if tap is within 10 meters of any existing hole
        for hole in currentCourse.holes {
            let holeLocation = CLLocation(latitude: hole.latitude, longitude: hole.longitude)
            if tappedLocation.distance(from: holeLocation) < 10 {
                return true
            }
        }
        return false
    }

    private func addHoleAtCurrentLocation() {
        guard let location = locationManager.location else { return }
        // When adding hole at current location, user and hole are at same spot
        // Pass user location so crop can be centered properly
        store.addHole(to: currentCourse, coordinate: location.coordinate, par: nil, userLocation: location.coordinate)
    }

    private func moveNearestHoleToCurrentLocation() {
        guard let location = locationManager.location,
              let nearest = nearestHole else { return }
        store.updateHole(nearest, in: currentCourse, newCoordinate: location.coordinate)
    }

    private func updateMapPosition() {
        if showingOverviewMap {
            guard !currentCourse.holes.isEmpty else { return }

            // Calculate region that fits all holes
            let coordinates = currentCourse.holes.map { $0.coordinate }
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
        } else {
            // Return to normal view
            if let firstHole = currentCourse.holes.first {
                position = .region(MKCoordinateRegion(
                    center: firstHole.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.001, longitudeDelta: 0.001)
                ))
            }
        }
    }
}
