import Foundation
import Combine
import CoreLocation

class WatchDataStore: ObservableObject {
    static let shared = WatchDataStore()

    @Published var currentRound: Round?
    @Published var currentHoleIndex: Int = 0
    @Published var pendingStrokes: [Stroke] = []
    @Published var availableClubs: [ClubData] = []
    @Published var clubTypes: [ClubTypeData] = []
    @Published var satelliteModeEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(satelliteModeEnabled, forKey: "satelliteModeEnabled")
        }
    }

    private let connectivity = WatchConnectivityManager.shared
    private let roundKey = "currentRound"
    private let pendingStrokesKey = "pendingStrokes"
    private let clubsKey = "availableClubs"
    private let clubTypesKey = "clubTypes"

    private init() {
        loadFromStorage()
        setupConnectivity()
    }

    // MARK: - Current Hole

    var currentHole: Hole? {
        guard let round = currentRound,
              let course = getCourse(for: round) else { return nil }
        guard currentHoleIndex < course.holes.count else { return nil }
        return course.holes[currentHoleIndex]
    }

    func getCourse(for round: Round) -> Course? {
        // Use holes from the synced round data
        return Course(
            id: round.courseId,
            name: round.courseName,
            holes: round.holes,
            rating: nil,
            slope: nil,
            city: nil
        )
    }

    // MARK: - Stroke Management

    func addStroke(clubId: UUID, trajectoryHeading: Double? = nil) {
        guard var round = currentRound,
              let location = LocationManager.shared.location else { return }

        // Determine hole number - use current hole if it exists, otherwise use next hole number
        let holeNumber: Int
        if let hole = currentHole {
            holeNumber = hole.number
        } else {
            // No hole defined yet - use the next hole number
            let course = getCourse(for: round)
            holeNumber = (course?.holes.count ?? 0) + 1
        }

        let strokesForHole = round.strokes.filter { $0.holeNumber == holeNumber }
        let strokeNumber = strokesForHole.count + 1

        let stroke = Stroke(
            holeNumber: holeNumber,
            strokeNumber: strokeNumber,
            coordinate: location.coordinate,
            clubId: clubId,
            trajectoryHeading: trajectoryHeading
        )

        // Add to current round
        round.strokes.append(stroke)
        currentRound = round

        // Add to pending sync queue
        pendingStrokes.append(stroke)

        // Save locally
        saveToStorage()

        // Try to sync immediately
        syncStrokes()
    }

    // MARK: - Round State Management (with automatic sync)

    func updateCurrentHoleIndex(newIndex: Int) {
        guard var round = currentRound else { return }

        currentHoleIndex = newIndex
        round.currentHoleIndex = newIndex
        currentRound = round
        saveToStorage()

        // Sync to iPhone
        WatchConnectivityManager.shared.sendRound(round)
    }

    func completeHole(holeNumber: Int) {
        guard var round = currentRound else { return }

        round.completedHoles.insert(holeNumber)
        currentRound = round
        saveToStorage()

        // Sync to iPhone
        WatchConnectivityManager.shared.sendRound(round)
    }

    func reopenHole(holeNumber: Int) {
        guard var round = currentRound else { return }

        round.completedHoles.remove(holeNumber)
        currentRound = round
        saveToStorage()

        // Sync to iPhone
        WatchConnectivityManager.shared.sendRound(round)
    }

    func moveToNextHole() {
        guard let course = getCourse(for: currentRound ?? Round(courseId: UUID(), courseName: "", holes: [])) else { return }

        if currentHoleIndex < course.holes.count - 1 {
            updateCurrentHoleIndex(newIndex: currentHoleIndex + 1)
        }
    }

    func moveToPreviousHole() {
        if currentHoleIndex > 0 {
            updateCurrentHoleIndex(newIndex: currentHoleIndex - 1)
        }
    }

    func deleteLastStroke() {
        guard var round = currentRound else { return }

        // Get strokes for current hole
        let hole = currentHole
        let strokesForHole = hole.map { h in round.strokes.filter { $0.holeNumber == h.number } } ?? []

        // If current hole is finished, just reopen it (don't delete strokes or move back)
        if let hole = hole, round.isHoleCompleted(hole.number) {
            reopenHole(holeNumber: hole.number)
            print("⌚ [WatchDataStore] Reopened finished hole \(hole.number)")
            return
        }

        // If there are strokes on current hole, delete the last one
        if let lastStroke = strokesForHole.last,
           let index = round.strokes.firstIndex(where: { $0.id == lastStroke.id }) {
            round.strokes.remove(at: index)
            currentRound = round

            // Also remove from pending if it's there
            if let pendingIndex = pendingStrokes.firstIndex(where: { $0.id == lastStroke.id }) {
                pendingStrokes.remove(at: pendingIndex)
            }

            saveToStorage()
            print("⌚ [WatchDataStore] Deleted last stroke")

            // Send update to iPhone
            WatchConnectivityManager.shared.sendRound(round)
        } else if currentHoleIndex > 0,
                  let course = getCourse(for: round) {
            // No strokes on current hole - check if we just finished the previous hole
            let previousHoleIdx = currentHoleIndex - 1
            let previousHoleNumber = course.holes[previousHoleIdx].number

            if round.isHoleCompleted(previousHoleNumber) {
                // Undo the hole completion and go back to previous hole
                reopenHole(holeNumber: previousHoleNumber)
                updateCurrentHoleIndex(newIndex: previousHoleIdx)
                print("⌚ [WatchDataStore] Undid hole completion, moved back to hole \(previousHoleNumber)")
            }
        }
    }

    // MARK: - Sync

    private func syncStrokes() {
        guard !pendingStrokes.isEmpty else { return }

        print("⌚ [WatchDataStore] Syncing \(pendingStrokes.count) pending strokes to iPhone")
        connectivity.sendStrokes(pendingStrokes) { [weak self] success in
            if success {
                print("⌚ [WatchDataStore] Successfully synced strokes, clearing pending queue")
                DispatchQueue.main.async {
                    self?.pendingStrokes.removeAll()
                    self?.saveToStorage()
                }
            } else {
                print("⌚ [WatchDataStore] Failed to sync strokes, will retry later")
            }
        }
    }

    // MARK: - Connectivity Setup

    private func setupConnectivity() {
        connectivity.onReceiveRound = { [weak self] round in
            print("⌚ [WatchDataStore] Received round: \(round.courseName)")
            print("⌚ [WatchDataStore] Round has \(round.holes.count) holes, current hole index: \(round.currentHoleIndex)")
            DispatchQueue.main.async {
                self?.currentRound = round
                self?.currentHoleIndex = round.currentHoleIndex
                self?.saveToStorage()
                print("⌚ [WatchDataStore] Current round set successfully, synced to hole \(round.currentHoleIndex)")
            }
        }

        connectivity.onReceiveClubs = { [weak self] clubs in
            print("⌚ [WatchDataStore] Received \(clubs.count) clubs from iPhone")
            DispatchQueue.main.async {
                self?.availableClubs = clubs
                self?.saveToStorage()
                print("⌚ [WatchDataStore] Clubs synced successfully")
            }
        }

        connectivity.onReceiveClubTypes = { [weak self] types in
            print("⌚ [WatchDataStore] Received \(types.count) club types from iPhone")
            DispatchQueue.main.async {
                self?.clubTypes = types
                self?.saveToStorage()
                print("⌚ [WatchDataStore] Club types synced successfully")
            }
        }
    }

    // MARK: - Persistence

    func saveToStorage() {
        if let round = currentRound,
           let data = try? JSONEncoder().encode(round) {
            UserDefaults.standard.set(data, forKey: roundKey)
        }

        if let data = try? JSONEncoder().encode(pendingStrokes) {
            UserDefaults.standard.set(data, forKey: pendingStrokesKey)
        }

        if let data = try? JSONEncoder().encode(availableClubs) {
            UserDefaults.standard.set(data, forKey: clubsKey)
        }

        if let data = try? JSONEncoder().encode(clubTypes) {
            UserDefaults.standard.set(data, forKey: clubTypesKey)
        }

        UserDefaults.standard.set(currentHoleIndex, forKey: "currentHoleIndex")
    }

    private func loadFromStorage() {
        if let data = UserDefaults.standard.data(forKey: roundKey),
           let round = try? JSONDecoder().decode(Round.self, from: data) {
            currentRound = round
        }

        if let data = UserDefaults.standard.data(forKey: pendingStrokesKey),
           let strokes = try? JSONDecoder().decode([Stroke].self, from: data) {
            pendingStrokes = strokes
        }

        if let data = UserDefaults.standard.data(forKey: clubsKey),
           let clubs = try? JSONDecoder().decode([ClubData].self, from: data) {
            availableClubs = clubs
            print("⌚ [WatchDataStore] Loaded \(clubs.count) clubs from storage")
        } else {
            print("⌚ [WatchDataStore] No clubs in storage, waiting for sync from iPhone")
        }

        if let data = UserDefaults.standard.data(forKey: clubTypesKey),
           let types = try? JSONDecoder().decode([ClubTypeData].self, from: data) {
            clubTypes = types
            print("⌚ [WatchDataStore] Loaded \(types.count) club types from storage")
        } else {
            print("⌚ [WatchDataStore] No club types in storage, waiting for sync from iPhone")
        }

        currentHoleIndex = UserDefaults.standard.integer(forKey: "currentHoleIndex")

        // Load satellite mode setting (defaults to true if not set)
        if UserDefaults.standard.object(forKey: "satelliteModeEnabled") != nil {
            satelliteModeEnabled = UserDefaults.standard.bool(forKey: "satelliteModeEnabled")
        }
    }

    // MARK: - Hole Completion

    func finishCurrentHole() {
        guard let hole = currentHole,
              let course = getCourse(for: currentRound ?? Round(courseId: UUID(), courseName: "", holes: [])) else { return }

        // Mark hole as completed
        completeHole(holeNumber: hole.number)

        // Auto-advance to next hole if available
        if currentHoleIndex < course.holes.count - 1 {
            updateCurrentHoleIndex(newIndex: currentHoleIndex + 1)
        }
    }

    func isHoleCompleted(_ holeNumber: Int) -> Bool {
        return currentRound?.isHoleCompleted(holeNumber) ?? false
    }

    // MARK: - Hole Management

    func addHole(coordinate: CLLocationCoordinate2D, par: Int? = nil) {
        guard var round = currentRound else { return }

        // Get current course to determine next hole number
        let course = getCourse(for: round)
        let nextHoleNumber = (course?.holes.count ?? 0) + 1

        // Create new hole
        let newHole = Hole(
            number: nextHoleNumber,
            coordinate: coordinate,
            par: par
        )

        // Add hole to round's holes array
        round.holes.append(newHole)

        // Update hole index in the round
        round.currentHoleIndex = nextHoleNumber - 1

        // Update local state
        currentRound = round
        currentHoleIndex = nextHoleNumber - 1

        // Save and sync - send everything together in ONE update
        saveToStorage()
        WatchConnectivityManager.shared.sendRound(round)

        print("⌚ [WatchDataStore] Added hole \(nextHoleNumber)\(par.map { " with par \($0)" } ?? "") and navigated to it")
    }

    func updateHole(holeNumber: Int, newCoordinate: CLLocationCoordinate2D, par: Int? = nil) {
        guard var round = currentRound else { return }

        // Find and update the hole in the round's holes array
        guard let holeIndex = round.holes.firstIndex(where: { $0.number == holeNumber }) else { return }

        round.holes[holeIndex].latitude = newCoordinate.latitude
        round.holes[holeIndex].longitude = newCoordinate.longitude

        // Update par if provided
        if let par = par {
            round.holes[holeIndex].par = par
        }

        // Update local state
        currentRound = round

        // Save and sync
        saveToStorage()
        WatchConnectivityManager.shared.sendRound(round)

        print("⌚ [WatchDataStore] Updated hole \(holeNumber) location\(par.map { " and par to \($0)" } ?? "")")
    }

    func navigateToNextHole() {
        guard var round = currentRound else { return }
        guard let course = getCourse(for: round) else { return }

        let nextIndex = currentHoleIndex + 1
        guard nextIndex < course.holes.count else { return }

        currentHoleIndex = nextIndex
        round.currentHoleIndex = nextIndex
        currentRound = round

        saveToStorage()
        WatchConnectivityManager.shared.sendRound(round)

        print("⌚ [WatchDataStore] Navigated to hole \(nextIndex + 1)")
    }

    func navigateToPreviousHole() {
        guard var round = currentRound else { return }

        let prevIndex = currentHoleIndex - 1
        guard prevIndex >= 0 else { return }

        currentHoleIndex = prevIndex
        round.currentHoleIndex = prevIndex
        currentRound = round

        saveToStorage()
        WatchConnectivityManager.shared.sendRound(round)

        print("⌚ [WatchDataStore] Navigated to hole \(prevIndex + 1)")
    }

    // MARK: - Quick Start Round

    func startQuickRound() {
        // Create a new round with "Quick Start" course
        let quickStartCourseId = UUID()
        let newRound = Round(
            courseId: quickStartCourseId,
            courseName: "Quick Start",
            holes: [] // Empty - user will add holes as they play
        )

        // Set as current round
        currentRound = newRound
        currentHoleIndex = 0

        // Save locally
        saveToStorage()

        // Sync to iPhone
        WatchConnectivityManager.shared.sendRound(newRound)

        print("⌚ [WatchDataStore] Started Quick Start round")
    }

    // MARK: - Helpers

    func strokeCount(for hole: Hole) -> Int {
        currentRound?.strokes.filter { $0.holeNumber == hole.number }.count ?? 0
    }

    func getClub(byId id: UUID) -> ClubData? {
        return availableClubs.first { $0.id == id }
    }

    func getClubType(byId id: UUID) -> ClubTypeData? {
        return clubTypes.first { $0.id == id }
    }

    func getTypeName(for club: ClubData) -> String {
        return clubTypes.first { $0.id == club.clubTypeId }?.name ?? club.name
    }
}
