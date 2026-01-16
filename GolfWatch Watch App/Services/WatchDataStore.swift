import Foundation
import Combine
import CoreLocation

// MARK: - Club Prediction Mode

enum ClubPredictionMode: String, Codable, CaseIterable {
    case off = "Off"
    case naive = "Naive"
    case smart = "Smart"
    case manual = "Manual"
}

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

    @Published var clubPredictionMode: ClubPredictionMode = .off {
        didSet {
            UserDefaults.standard.set(clubPredictionMode.rawValue, forKey: "clubPredictionMode")
        }
    }

    // Custom club averages for Manual mode (keyed by club type name)
    @Published var customClubAverages: [String: Int] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(customClubAverages) {
                UserDefaults.standard.set(data, forKey: "customClubAverages")
            }
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

        // Load club prediction mode setting (defaults to .off)
        if let modeString = UserDefaults.standard.string(forKey: "clubPredictionMode"),
           let mode = ClubPredictionMode(rawValue: modeString) {
            clubPredictionMode = mode
        }

        // Load custom club averages for Manual mode
        if let data = UserDefaults.standard.data(forKey: "customClubAverages"),
           let averages = try? JSONDecoder().decode([String: Int].self, from: data) {
            customClubAverages = averages
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

// MARK: - Club Prediction Manager

class ClubPredictionManager {
    static let shared = ClubPredictionManager()

    // Naive mode default distances (in yards) - used when clubType.averageDistance is nil
    private let naiveDistances: [String: Int] = [
        "Driver": 245,
        "3-Wood": 225,
        "5-Wood": 207,
        "4-Hybrid": 192,
        "5-Hybrid": 180,
        "4-Iron": 170,
        "5-Iron": 160,
        "6-Iron": 150,
        "7-Iron": 140,
        "8-Iron": 130,
        "9-Iron": 118,
        "Pitch": 106,
        "Gap": 93,
        "Sand": 78,
        "Lob": 45,
        "Putter": 10
    ]

    private init() {}

    /// Get the average distance for a club type based on mode and custom settings
    func getAverage(for clubTypeName: String, mode: ClubPredictionMode, customAverages: [String: Int]) -> Int {
        switch mode {
        case .naive, .smart:
            return naiveDistances[clubTypeName] ?? 100
        case .manual:
            return customAverages[clubTypeName] ?? naiveDistances[clubTypeName] ?? 100
        case .off:
            return naiveDistances[clubTypeName] ?? 100
        }
    }

    /// Find the best club index for a given distance
    func predictClubIndex(forDistance yards: Int, clubs: [ClubData], clubTypes: [ClubTypeData], mode: ClubPredictionMode, customAverages: [String: Int] = [:]) -> Int? {
        guard mode != .off, !clubs.isEmpty else { return nil }

        // Build list of (clubIndex, averageDistance) for all available clubs
        var clubDistances: [(index: Int, average: Int, name: String)] = []

        for (index, club) in clubs.enumerated() {
            guard let clubType = clubTypes.first(where: { $0.id == club.clubTypeId }) else { continue }

            let average = getAverage(for: clubType.name, mode: mode, customAverages: customAverages)
            clubDistances.append((index, average, clubType.name))
        }

        guard !clubDistances.isEmpty else { return nil }

        // Sort by average distance (descending - longest clubs first)
        clubDistances.sort { $0.average > $1.average }

        // Calculate ranges as midpoints between adjacent clubs
        for i in 0..<clubDistances.count {
            let current = clubDistances[i]

            let maxYards: Int
            if i == 0 {
                maxYards = Int.max
            } else {
                let previous = clubDistances[i - 1]
                maxYards = (current.average + previous.average) / 2
            }

            let minYards: Int
            if i == clubDistances.count - 1 {
                minYards = 0
            } else {
                let next = clubDistances[i + 1]
                minYards = (current.average + next.average) / 2
            }

            if yards >= minYards && yards < maxYards {
                return current.index
            }
        }

        return clubDistances.last?.index
    }
}
