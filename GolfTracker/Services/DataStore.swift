import Foundation
import CoreLocation

class DataStore: ObservableObject {
    @Published var courses: [Course] = []
    @Published var rounds: [Round] = []
    @Published var errorMessage: String?

    private let coursesFileName = "courses.json"
    private let roundsFileName = "rounds.json"

    init() {
        print("🏌️ DataStore initialized!")
        loadCourses()
        loadRounds()
        print("🏌️ DataStore loaded \(courses.count) courses and \(rounds.count) rounds")

        // Set up Watch Connectivity callbacks
        setupWatchConnectivity()
    }

    private func setupWatchConnectivity() {
        WatchConnectivityManager.shared.onReceiveStrokes = { [weak self] strokes in
            print("📱 [DataStore] Received \(strokes.count) strokes from Watch")
            self?.mergeStrokesFromWatch(strokes)
        }

        WatchConnectivityManager.shared.onReceiveRound = { [weak self] round in
            print("📱 [DataStore] Received round update from Watch: \(round.courseName)")
            self?.updateRoundFromWatch(round)
        }
    }

    private func mergeStrokesFromWatch(_ strokes: [Stroke]) {
        // Find the active round and add the strokes
        guard let activeRoundIndex = rounds.firstIndex(where: { round in
            // The most recent round is likely the active one
            round.date == rounds.max(by: { $0.date < $1.date })?.date
        }) else {
            print("📱 [DataStore] ERROR: No active round found to add strokes to")
            return
        }

        print("📱 [DataStore] Adding strokes to round: \(rounds[activeRoundIndex].courseName)")

        for stroke in strokes {
            // Check if stroke already exists (avoid duplicates)
            let strokeExists = rounds[activeRoundIndex].strokes.contains(where: { $0.id == stroke.id })
            if !strokeExists {
                rounds[activeRoundIndex].strokes.append(stroke)
                print("📱 [DataStore] Added stroke \(stroke.strokeNumber) on hole \(stroke.holeNumber)")
            } else {
                print("📱 [DataStore] Stroke already exists, skipping")
            }
        }

        saveRounds()
        print("📱 [DataStore] Saved round with \(rounds[activeRoundIndex].strokes.count) total strokes")
    }

    private func updateRoundFromWatch(_ watchRound: Round) {
        // Find the round by ID
        guard let roundIndex = rounds.firstIndex(where: { $0.id == watchRound.id }) else {
            print("📱 [DataStore] ERROR: Round not found for update")
            return
        }

        // Update everything from Watch
        rounds[roundIndex].holes = watchRound.holes
        rounds[roundIndex].completedHoles = watchRound.completedHoles
        rounds[roundIndex].currentHoleIndex = watchRound.currentHoleIndex
        rounds[roundIndex].targets = watchRound.targets
        rounds[roundIndex].strokes = watchRound.strokes

        // Also update the course with the new holes
        if let courseIndex = courses.firstIndex(where: { $0.id == watchRound.courseId }) {
            courses[courseIndex].holes = watchRound.holes
            saveCourses()
        }

        saveRounds()
        print("📱 [DataStore] Updated round from Watch: \(watchRound.strokes.count) strokes, \(watchRound.completedHoles.count) holes completed, current hole index: \(watchRound.currentHoleIndex)")
    }

    private var coursesFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(coursesFileName)
    }

    private var roundsFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(roundsFileName)
    }
    
    func loadCourses() {
        guard FileManager.default.fileExists(atPath: coursesFileURL.path) else { return }

        do {
            let data = try Data(contentsOf: coursesFileURL)
            courses = try JSONDecoder().decode([Course].self, from: data)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load courses: \(error.localizedDescription)"
        }
    }

    func loadRounds() {
        guard FileManager.default.fileExists(atPath: roundsFileURL.path) else { return }

        do {
            let data = try Data(contentsOf: roundsFileURL)
            rounds = try JSONDecoder().decode([Round].self, from: data)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load rounds: \(error.localizedDescription)"
        }
    }

    func saveCourses() {
        do {
            let data = try JSONEncoder().encode(courses)
            try data.write(to: coursesFileURL)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to save courses: \(error.localizedDescription)"
        }
    }

    func saveRounds() {
        do {
            let data = try JSONEncoder().encode(rounds)
            try data.write(to: roundsFileURL)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to save rounds: \(error.localizedDescription)"
        }
    }
    
    func addCourse(name: String) {
        let course = Course(name: name, holes: [])
        courses.append(course)
        saveCourses()
    }

    func deleteCourse(_ course: Course) {
        courses.removeAll { $0.id == course.id }
        saveCourses()
    }

    func updateCourseInfo(_ course: Course, name: String, rating: Double?, slope: Int?) {
        guard let index = courses.firstIndex(where: { $0.id == course.id }) else { return }
        courses[index].name = name
        courses[index].rating = rating
        courses[index].slope = slope
        saveCourses()
    }

    func updateCourseCity(_ course: Course) {
        guard let index = courses.firstIndex(where: { $0.id == course.id }),
              let coordinate = course.coordinate else { return }

        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            guard let self = self,
                  let placemark = placemarks?.first,
                  let city = placemark.locality else { return }

            DispatchQueue.main.async {
                if let currentIndex = self.courses.firstIndex(where: { $0.id == course.id }) {
                    self.courses[currentIndex].city = city
                    self.saveCourses()
                }
            }
        }
    }

    func addHole(to course: Course, coordinate: CLLocationCoordinate2D, par: Int? = nil) {
        guard let index = courses.firstIndex(where: { $0.id == course.id }) else { return }
        let holeNumber = courses[index].holes.count + 1
        let hole = Hole(number: holeNumber, coordinate: coordinate, par: par)
        courses[index].holes.append(hole)
        saveCourses()

        // Update city if this is the first hole or if city is not set
        if courses[index].city == nil {
            updateCourseCity(courses[index])
        }

        // Update active round with new hole data and resync to Watch
        updateActiveRoundHoles(for: course)
    }

    private func updateActiveRoundHoles(for course: Course) {
        // Find the most recent active round for this course
        guard let roundIndex = rounds.firstIndex(where: { round in
            round.courseId == course.id && round.date == rounds.max(by: { $0.date < $1.date })?.date
        }) else { return }

        // Update the round's holes with the latest from the course
        if let courseIndex = courses.firstIndex(where: { $0.id == course.id }) {
            let oldHoleCount = rounds[roundIndex].holes.count
            rounds[roundIndex].holes = courses[courseIndex].holes

            // If a new hole was added, update the current hole index to point to it
            if courses[courseIndex].holes.count > oldHoleCount {
                rounds[roundIndex].currentHoleIndex = courses[courseIndex].holes.count - 1
                print("📱 [DataStore] New hole added, updated currentHoleIndex to \(rounds[roundIndex].currentHoleIndex)")
            }

            saveRounds()

            // Resync to Watch
            print("📱 [DataStore] Updated active round holes, resyncing to Watch")
            WatchConnectivityManager.shared.sendRound(rounds[roundIndex])
        }
    }

    func deleteHole(_ hole: Hole, from course: Course) {
        guard let courseIndex = courses.firstIndex(where: { $0.id == course.id }) else { return }
        courses[courseIndex].holes.removeAll { $0.id == hole.id }
        // Renumber remaining holes
        for i in courses[courseIndex].holes.indices {
            courses[courseIndex].holes[i].number = i + 1
        }
        saveCourses()
        updateActiveRoundHoles(for: course)
    }

    func updateHole(_ hole: Hole, in course: Course, newCoordinate: CLLocationCoordinate2D, par: Int? = nil) {
        guard let courseIndex = courses.firstIndex(where: { $0.id == course.id }),
              let holeIndex = courses[courseIndex].holes.firstIndex(where: { $0.id == hole.id }) else { return }
        courses[courseIndex].holes[holeIndex].latitude = newCoordinate.latitude
        courses[courseIndex].holes[holeIndex].longitude = newCoordinate.longitude
        if let par = par {
            courses[courseIndex].holes[holeIndex].par = par
        }
        saveCourses()
        updateActiveRoundHoles(for: course)
    }

    func renumberHole(_ hole: Hole, in course: Course, newNumber: Int) {
        guard let courseIndex = courses.firstIndex(where: { $0.id == course.id }),
              let holeIndex = courses[courseIndex].holes.firstIndex(where: { $0.id == hole.id }) else { return }

        // Ensure new number is valid
        let clampedNumber = max(1, min(newNumber, courses[courseIndex].holes.count))

        // Remove hole from current position
        let removedHole = courses[courseIndex].holes.remove(at: holeIndex)

        // Insert at new position (newNumber - 1 because array is 0-indexed)
        let newIndex = clampedNumber - 1
        courses[courseIndex].holes.insert(removedHole, at: newIndex)

        // Renumber all holes sequentially
        for i in courses[courseIndex].holes.indices {
            courses[courseIndex].holes[i].number = i + 1
        }

        saveCourses()
        updateActiveRoundHoles(for: course)
    }


    // MARK: - Round Management

    func startRound(for course: Course) -> Round {
        print("📱 [DataStore] startRound called for course: \(course.name)")
        let round = Round(courseId: course.id, courseName: course.name, holes: course.holes)
        rounds.append(round)
        saveRounds()

        print("📱 [DataStore] About to send round to Watch, holes: \(round.holes.count)")
        // Send round to Watch
        WatchConnectivityManager.shared.sendRound(round)

        return round
    }

    func addStroke(to round: Round, holeNumber: Int, coordinate: CLLocationCoordinate2D, club: Club, trajectoryHeading: Double? = nil) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }) else { return }

        let strokesForHole = rounds[roundIndex].strokes.filter { $0.holeNumber == holeNumber }
        let strokeNumber = strokesForHole.count + 1

        let stroke = Stroke(holeNumber: holeNumber, strokeNumber: strokeNumber, coordinate: coordinate, club: club, trajectoryHeading: trajectoryHeading)
        rounds[roundIndex].strokes.append(stroke)
        saveRounds()

        // Send updated round to Watch
        WatchConnectivityManager.shared.sendRound(rounds[roundIndex])
    }

    func updateStrokeDetails(in round: Round, stroke: Stroke, direction: StrokeDirection?) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }),
              let strokeIndex = rounds[roundIndex].strokes.firstIndex(where: { $0.id == stroke.id }) else { return }

        rounds[roundIndex].strokes[strokeIndex].direction = direction

        saveRounds()
    }

    func endRound(_ round: Round) {
        // Round is already saved, just need to ensure it's persisted
        saveRounds()
    }

    func deleteRound(_ round: Round) {
        rounds.removeAll { $0.id == round.id }
        saveRounds()
    }

    func hasRounds(for course: Course) -> Bool {
        return rounds.contains { $0.courseId == course.id }
    }

    func updateStrokePosition(in round: Round, stroke: Stroke, newCoordinate: CLLocationCoordinate2D) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }),
              let strokeIndex = rounds[roundIndex].strokes.firstIndex(where: { $0.id == stroke.id }) else { return }

        rounds[roundIndex].strokes[strokeIndex].latitude = newCoordinate.latitude
        rounds[roundIndex].strokes[strokeIndex].longitude = newCoordinate.longitude

        saveRounds()
    }

    func deleteStroke(in round: Round, stroke: Stroke) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }) else { return }

        // Remove the stroke
        rounds[roundIndex].strokes.removeAll { $0.id == stroke.id }

        // Renumber remaining strokes for the same hole
        let holeNumber = stroke.holeNumber
        for i in rounds[roundIndex].strokes.indices {
            if rounds[roundIndex].strokes[i].holeNumber == holeNumber {
                // Recalculate stroke number based on position in filtered array
                let strokesForHole = rounds[roundIndex].strokes.filter { $0.holeNumber == holeNumber }
                if let indexInHole = strokesForHole.firstIndex(where: { $0.id == rounds[roundIndex].strokes[i].id }) {
                    rounds[roundIndex].strokes[i].strokeNumber = indexInHole + 1
                }
            }
        }

        saveRounds()

        // Send updated round to Watch
        WatchConnectivityManager.shared.sendRound(rounds[roundIndex])
    }

    func addPenaltyStroke(to round: Round, holeNumber: Int, coordinate: CLLocationCoordinate2D, club: Club) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }) else { return }

        let strokesForHole = rounds[roundIndex].strokes.filter { $0.holeNumber == holeNumber }
        let strokeNumber = strokesForHole.count + 1

        let stroke = Stroke(holeNumber: holeNumber, strokeNumber: strokeNumber, coordinate: coordinate, club: club, isPenalty: true)
        rounds[roundIndex].strokes.append(stroke)
        saveRounds()

        // Send updated round to Watch
        WatchConnectivityManager.shared.sendRound(rounds[roundIndex])
    }

    func renumberStroke(in round: Round, stroke: Stroke, newNumber: Int) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }),
              let strokeIndex = rounds[roundIndex].strokes.firstIndex(where: { $0.id == stroke.id }) else { return }

        let oldNumber = rounds[roundIndex].strokes[strokeIndex].strokeNumber
        let holeNumber = stroke.holeNumber

        // If the number didn't change, do nothing
        guard oldNumber != newNumber else { return }

        // Update the stroke number
        rounds[roundIndex].strokes[strokeIndex].strokeNumber = newNumber

        // Adjust other stroke numbers for the same hole
        for i in rounds[roundIndex].strokes.indices {
            if rounds[roundIndex].strokes[i].holeNumber == holeNumber &&
               rounds[roundIndex].strokes[i].id != stroke.id {
                let currentNumber = rounds[roundIndex].strokes[i].strokeNumber

                if oldNumber < newNumber {
                    // Moving stroke later: decrease numbers in between
                    if currentNumber > oldNumber && currentNumber <= newNumber {
                        rounds[roundIndex].strokes[i].strokeNumber -= 1
                    }
                } else {
                    // Moving stroke earlier: increase numbers in between
                    if currentNumber >= newNumber && currentNumber < oldNumber {
                        rounds[roundIndex].strokes[i].strokeNumber += 1
                    }
                }
            }
        }

        saveRounds()
    }

    // MARK: - Round State Management (with automatic sync)

    func updateCurrentHoleIndex(for round: Round, newIndex: Int) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }) else { return }

        rounds[roundIndex].currentHoleIndex = newIndex
        saveRounds()

        // Sync to Watch
        WatchConnectivityManager.shared.sendRound(rounds[roundIndex])
    }

    func completeHole(in round: Round, holeNumber: Int) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }) else { return }

        rounds[roundIndex].completedHoles.insert(holeNumber)
        saveRounds()

        // Sync to Watch
        WatchConnectivityManager.shared.sendRound(rounds[roundIndex])
    }

    func reopenHole(in round: Round, holeNumber: Int) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }) else { return }

        rounds[roundIndex].completedHoles.remove(holeNumber)
        saveRounds()

        // Sync to Watch
        WatchConnectivityManager.shared.sendRound(rounds[roundIndex])
    }
}
