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

    @Published var currentRound: Round? {
        didSet {
            let enabled = currentRound?.locationTestModeEnabled == true
            LocationManager.shared.setTestModeEnabled(enabled)
        }
    }
    @Published var pendingStrokes: [Stroke] = []
    @Published var availableClubs: [ClubData] = []
    @Published var clubTypes: [ClubTypeData] = []
    @Published var holeDetectionDataByCourse: [UUID: CourseHoleDetectionData] = [:]
    /// In-memory cache of OSM course data keyed by courseId. Populated when the
    /// resolver completes; consumed by AutoAdvanceMonitor's visited-green check
    /// and (eventually) by the round-play UI for green polygon overlays.
    /// Not persisted — if app relaunches, the resolver re-fetches (cache-fast).
    @Published var osmCourseDataByCourse: [UUID: OSMCourseData] = [:]
    @Published var holeFilterSettings: HoleDetectionFilterSettings = .default {
        didSet {
            if let data = try? JSONEncoder().encode(holeFilterSettings) {
                UserDefaults.standard.set(data, forKey: holeFilterSettingsKey)
            }
            // WC sync deferred to launch via setupConnectivity(); not sent on every stepper tap.
        }
    }

    /// Status string streamed during round start ("Locating course...",
    /// "Pebble Beach — loading data...", "Scanning greens 3/8…"). nil when
    /// no round-start flow is in progress.
    @Published var roundStartStatus: String?
    /// Set when the resolver returns multiple POI candidates within a tight
    /// radius and needs the user to pick. UI presents these and calls
    /// `pickPOICandidate(_:)` with the user's choice (or nil to cancel).
    @Published var pendingPOIPicker: [RoundResolver.POICandidate]?
    private var pendingPOIPickerCompletion: ((RoundResolver.POICandidate?) -> Void)?

    @Published var clubPredictionMode: ClubPredictionMode = .manual {
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

    // Club types disabled from predictions (keyed by club type name)
    @Published var disabledPredictionClubs: Set<String> = [] {
        didSet {
            if let data = try? JSONEncoder().encode(Array(disabledPredictionClubs)) {
                UserDefaults.standard.set(data, forKey: "disabledPredictionClubs")
            }
        }
    }

    private let connectivity = WatchConnectivityManager.shared
    private let roundKey = "currentRound"
    private let pendingStrokesKey = "pendingStrokes"
    private let clubsKey = "availableClubs"
    private let clubTypesKey = "clubTypes"
    private let holeDetectionDataKey = "holeDetectionDataByCourse"
    private let holeFilterSettingsKey = "holeFilterSettings"

    private init() {
        loadFromStorage()
        setupConnectivity()
        // Touch the auto-advance monitor so its location subscription wires up
        // immediately at app launch (the monitor self-gates on `enabled`
        // and on whether the active round has next-hole coords).
        _ = AutoAdvanceMonitor.shared
    }

    // MARK: - Current Hole

    /// Single source of truth — derived from the round to avoid dual-state drift.
    var currentHoleIndex: Int { currentRound?.currentHoleIndex ?? 0 }

    var currentHole: Hole? {
        guard let round = currentRound else { return nil }
        guard currentHoleIndex < round.holes.count else { return nil }
        return round.holes[currentHoleIndex]
    }

    // MARK: - Stroke Management

    @discardableResult
    func addStroke(clubId: UUID, trajectoryHeading: Double? = nil, coordinate: CLLocationCoordinate2D? = nil, isPenalty: Bool = false) -> UUID? {
        guard var round = currentRound else { return nil }
        guard let strokeCoordinate = coordinate ?? LocationManager.shared.location?.coordinate else { return nil }

        // Determine hole number - use current hole if it exists, otherwise use next hole number
        let holeNumber: Int
        if let hole = currentHole {
            holeNumber = hole.number
        } else {
            holeNumber = round.holes.count + 1
        }

        let strokeNumber = Stroke.nextStrokeNumber(in: round, holeNumber: holeNumber)

        let stroke = Stroke(
            holeNumber: holeNumber,
            strokeNumber: strokeNumber,
            coordinate: strokeCoordinate,
            clubId: clubId,
            isPenalty: isPenalty,
            trajectoryHeading: trajectoryHeading
        )

        round.strokes.append(stroke)
        currentRound = round

        pendingStrokes.append(stroke)

        saveRound()
        savePendingStrokes()
        syncStrokes()
        return stroke.id
    }

    func updateStrokeClub(strokeId: UUID, clubId: UUID) {
        guard var round = currentRound else { return }
        guard let index = round.strokes.firstIndex(where: { $0.id == strokeId }) else { return }
        round.strokes[index].clubId = clubId
        currentRound = round
        saveRound()
        syncStrokes()
    }

    // MARK: - Round State Management (with automatic sync)

    func updateCurrentHoleIndex(newIndex: Int) {
        guard var round = currentRound else { return }

        round.currentHoleIndex = newIndex
        currentRound = round
        saveRound()

        WatchConnectivityManager.shared.sendRound(round)
    }

    func completeHole(holeNumber: Int) {
        guard var round = currentRound else { return }

        round.completedHoles.insert(holeNumber)
        currentRound = round
        saveRound()

        WatchConnectivityManager.shared.sendRound(round)
    }

    func reopenHole(holeNumber: Int) {
        guard var round = currentRound else { return }

        round.completedHoles.remove(holeNumber)
        currentRound = round
        saveRound()

        WatchConnectivityManager.shared.sendRound(round)
    }

    func deleteLastStroke() {
        guard var round = currentRound else { return }

        let hole = currentHole
        let strokesForHole = hole.map { h in round.strokes.filter { $0.holeNumber == h.number } } ?? []

        // If current hole is finished, just reopen it (don't delete strokes or move back)
        if let hole = hole, round.isHoleCompleted(hole.number) {
            reopenHole(holeNumber: hole.number)
            dprint("⌚ [WatchDataStore] Reopened finished hole \(hole.number)")
            return
        }

        // If there are strokes on current hole, delete the last one
        if let lastStroke = strokesForHole.last,
           let index = round.strokes.firstIndex(where: { $0.id == lastStroke.id }) {
            round.strokes.remove(at: index)
            currentRound = round

            if let pendingIndex = pendingStrokes.firstIndex(where: { $0.id == lastStroke.id }) {
                pendingStrokes.remove(at: pendingIndex)
            }

            saveRound()
            savePendingStrokes()
            dprint("⌚ [WatchDataStore] Deleted last stroke")

            WatchConnectivityManager.shared.sendRound(round)
        } else if currentHoleIndex > 0 {
            // No strokes on current hole - check if we just finished the previous hole
            let previousHoleIdx = currentHoleIndex - 1
            let previousHoleNumber = round.holes[previousHoleIdx].number

            if round.isHoleCompleted(previousHoleNumber) {
                reopenHole(holeNumber: previousHoleNumber)
                updateCurrentHoleIndex(newIndex: previousHoleIdx)
                dprint("⌚ [WatchDataStore] Undid hole completion, moved back to hole \(previousHoleNumber)")
            }
        }
    }

    // MARK: - Sync

    private func syncStrokes() {
        guard !pendingStrokes.isEmpty else { return }

        dprint("⌚ [WatchDataStore] Syncing \(pendingStrokes.count) pending strokes to iPhone")
        connectivity.sendStrokes(pendingStrokes) { [weak self] success in
            if success {
                dprint("⌚ [WatchDataStore] Successfully synced strokes, clearing pending queue")
                DispatchQueue.main.async {
                    self?.pendingStrokes.removeAll()
                    self?.savePendingStrokes()
                }
            } else {
                dprint("⌚ [WatchDataStore] Failed to sync strokes, will retry later")
            }
        }
    }

    // MARK: - Connectivity Setup

    private func setupConnectivity() {
        connectivity.onReceiveRound = { [weak self] round in
            dprint("⌚ [WatchDataStore] Received round: \(round.courseName)")
            dprint("⌚ [WatchDataStore] Round has \(round.holes.count) holes, current hole index: \(round.currentHoleIndex)")
            DispatchQueue.main.async {
                self?.currentRound = round
                self?.saveToStorage()
                dprint("⌚ [WatchDataStore] Current round set successfully, synced to hole \(round.currentHoleIndex)")
            }
        }

        connectivity.onReceiveClubs = { [weak self] clubs in
            dprint("⌚ [WatchDataStore] Received \(clubs.count) clubs from iPhone")
            DispatchQueue.main.async {
                self?.availableClubs = clubs
                self?.saveToStorage()
                dprint("⌚ [WatchDataStore] Clubs synced successfully")
            }
        }

        connectivity.onReceiveClubTypes = { [weak self] types in
            dprint("⌚ [WatchDataStore] Received \(types.count) club types from iPhone")
            DispatchQueue.main.async {
                self?.clubTypes = types
                self?.saveToStorage()
                dprint("⌚ [WatchDataStore] Club types synced successfully")
            }
        }

        connectivity.onReceiveHoleDetectionData = { [weak self] detectionData in
            dprint("⌚ [WatchDataStore] Received hole detection data for course \(detectionData.courseId), blobs: \(detectionData.blobs.count)")
            DispatchQueue.main.async {
                self?.holeDetectionDataByCourse[detectionData.courseId] = detectionData
                self?.saveToStorage()
            }
        }

        // Watch is the authority for filter settings — push current value to iPhone on launch.
        connectivity.sendHoleFilterSettings(holeFilterSettings)
    }

    // MARK: - Persistence

    private func saveRound() {
        if let round = currentRound,
           let data = try? JSONEncoder().encode(round) {
            UserDefaults.standard.set(data, forKey: roundKey)
        }
    }

    private func savePendingStrokes() {
        if let data = try? JSONEncoder().encode(pendingStrokes) {
            UserDefaults.standard.set(data, forKey: pendingStrokesKey)
        }
    }

    func saveToStorage() {
        saveRound()
        savePendingStrokes()

        if let data = try? JSONEncoder().encode(availableClubs) {
            UserDefaults.standard.set(data, forKey: clubsKey)
        }

        if let data = try? JSONEncoder().encode(clubTypes) {
            UserDefaults.standard.set(data, forKey: clubTypesKey)
        }

        let detectionDataArray = Array(holeDetectionDataByCourse.values)
        if let data = try? JSONEncoder().encode(detectionDataArray) {
            UserDefaults.standard.set(data, forKey: holeDetectionDataKey)
        }

        if let data = try? JSONEncoder().encode(holeFilterSettings) {
            UserDefaults.standard.set(data, forKey: holeFilterSettingsKey)
        }
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
            dprint("⌚ [WatchDataStore] Loaded \(clubs.count) clubs from storage")
        } else {
            dprint("⌚ [WatchDataStore] No clubs in storage, waiting for sync from iPhone")
        }

        if let data = UserDefaults.standard.data(forKey: clubTypesKey),
           let types = try? JSONDecoder().decode([ClubTypeData].self, from: data) {
            clubTypes = types
            dprint("⌚ [WatchDataStore] Loaded \(types.count) club types from storage")
        } else {
            dprint("⌚ [WatchDataStore] No club types in storage, waiting for sync from iPhone")
        }

        if let data = UserDefaults.standard.data(forKey: holeDetectionDataKey),
           let detectionDataArray = try? JSONDecoder().decode([CourseHoleDetectionData].self, from: data) {
            holeDetectionDataByCourse = Dictionary(uniqueKeysWithValues: detectionDataArray.map { ($0.courseId, $0) })
            dprint("⌚ [WatchDataStore] Loaded hole detection data for \(holeDetectionDataByCourse.count) course(s)")
        }

        if let data = UserDefaults.standard.data(forKey: holeFilterSettingsKey),
           let settings = try? JSONDecoder().decode(HoleDetectionFilterSettings.self, from: data) {
            holeFilterSettings = settings
        }

        if let modeString = UserDefaults.standard.string(forKey: "clubPredictionMode"),
           let mode = ClubPredictionMode(rawValue: modeString) {
            clubPredictionMode = mode
        }

        if let data = UserDefaults.standard.data(forKey: "customClubAverages"),
           let averages = try? JSONDecoder().decode([String: Int].self, from: data) {
            customClubAverages = averages
        }

        if let data = UserDefaults.standard.data(forKey: "disabledPredictionClubs"),
           let names = try? JSONDecoder().decode([String].self, from: data) {
            disabledPredictionClubs = Set(names)
        }
    }

    // MARK: - Hole Completion

    func finishCurrentHole() {
        guard let hole = currentHole,
              let round = currentRound else { return }

        completeHole(holeNumber: hole.number)

        if currentHoleIndex < round.holes.count - 1 {
            updateCurrentHoleIndex(newIndex: currentHoleIndex + 1)
        }
    }

    func isHoleCompleted(_ holeNumber: Int) -> Bool {
        return currentRound?.isHoleCompleted(holeNumber) ?? false
    }

    // MARK: - Hole Management

    /// Adds the next hole without coordinates (user will place flag)
    func addNextHole() {
        guard var round = currentRound else { return }

        let nextHoleNumber = round.holes.count + 1
        let newHole = Hole(number: nextHoleNumber)

        round.holes.append(newHole)
        round.currentHoleIndex = nextHoleNumber - 1
        currentRound = round

        saveRound()
        WatchConnectivityManager.shared.sendRound(round)

        dprint("⌚ [WatchDataStore] Added hole \(nextHoleNumber) (awaiting flag placement)")
    }

    func addHole(coordinate: CLLocationCoordinate2D, par: Int? = nil) {
        guard var round = currentRound else { return }

        let nextHoleNumber = round.holes.count + 1
        let newHole = Hole(
            number: nextHoleNumber,
            coordinate: coordinate,
            par: par
        )

        round.holes.append(newHole)
        round.currentHoleIndex = nextHoleNumber - 1
        currentRound = round

        saveRound()
        WatchConnectivityManager.shared.sendRound(round)

        dprint("⌚ [WatchDataStore] Added hole \(nextHoleNumber)\(par.map { " with par \($0)" } ?? "") and navigated to it")
    }

    func updateHole(holeNumber: Int, newCoordinate: CLLocationCoordinate2D, par: Int? = nil) {
        guard var round = currentRound else { return }

        guard let holeIndex = round.holes.firstIndex(where: { $0.number == holeNumber }) else { return }

        round.holes[holeIndex].latitude = newCoordinate.latitude
        round.holes[holeIndex].longitude = newCoordinate.longitude

        if let par = par {
            round.holes[holeIndex].par = par
        }

        currentRound = round

        saveRound()
        WatchConnectivityManager.shared.sendRound(round)

        dprint("⌚ [WatchDataStore] Updated hole \(holeNumber) location\(par.map { " and par to \($0)" } ?? "")")
    }

    func navigateToNextHole() {
        guard var round = currentRound else { return }

        let nextIndex = currentHoleIndex + 1
        guard nextIndex < round.holes.count else { return }

        round.currentHoleIndex = nextIndex
        currentRound = round

        saveRound()
        WatchConnectivityManager.shared.sendRound(round)

        dprint("⌚ [WatchDataStore] Navigated to hole \(nextIndex + 1)")
    }

    func navigateToPreviousHole() {
        guard var round = currentRound else { return }

        let prevIndex = currentHoleIndex - 1
        guard prevIndex >= 0 else { return }

        round.currentHoleIndex = prevIndex
        currentRound = round

        saveRound()
        WatchConnectivityManager.shared.sendRound(round)

        // Re-arm auto-advance — user manually went back, so re-leaving this
        // hole should be allowed to fire again.
        AutoAdvanceMonitor.shared.resetForCurrentHole()

        dprint("⌚ [WatchDataStore] Navigated to hole \(prevIndex + 1)")
    }

    // MARK: - Start Round (resolver-backed)

    /// Kick off a new round at the user's current GPS. The resolver handles:
    ///   - MapKit POI search for nearby golf courses
    ///   - Existing-course proximity match against the user's Supabase rounds
    ///   - OSM geometry resolve (cache hit fast path; Overpass fetch on miss)
    ///   - Tier classification — full / partial / none
    ///
    /// Behavior by tier:
    ///   - **full**: round opens with all 18 holes pre-placed from OSM data,
    ///     no manual hole prompts.
    ///   - **partial**: round opens with one empty hole; user picks greens
    ///     from the OSM polygon set as they advance.
    ///   - **none** (or no GPS / no POIs): falls back to the legacy
    ///     "Quick Start" behavior — one empty hole, user places everything.
    func startRoundAtCurrentLocation() {
        let coordinate: CLLocationCoordinate2D
        if let loc = LocationManager.shared.location?.coordinate {
            coordinate = loc
        } else {
            dprint("⌚ [WatchDataStore] No GPS — falling back to manual quick-start")
            startManualQuickRound()
            return
        }
        roundStartStatus = "Locating course…"
        RoundResolver.shared.resolve(
            at: coordinate,
            progress: { [weak self] step in
                DispatchQueue.main.async {
                    self?.roundStartStatus = WatchDataStore.statusString(for: step)
                }
            },
            coursePicker: { [weak self] candidates, choose in
                DispatchQueue.main.async {
                    self?.pendingPOIPicker = candidates
                    self?.pendingPOIPickerCompletion = choose
                }
            },
            completion: { [weak self] resolution in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.roundStartStatus = nil
                    if let resolution = resolution {
                        self.startRound(from: resolution)
                    } else {
                        self.startManualQuickRound()
                    }
                }
            }
        )
    }

    /// Caller (the picker UI) hands back the user's pick. Resumes the resolver
    /// chain that's blocked on `pendingPOIPicker`.
    func pickPOICandidate(_ candidate: RoundResolver.POICandidate?) {
        let cb = pendingPOIPickerCompletion
        pendingPOIPicker = nil
        pendingPOIPickerCompletion = nil
        cb?(candidate)
    }

    func osmCourseData(forCourseId id: UUID) -> OSMCourseData? {
        osmCourseDataByCourse[id]
    }

    private func startRound(from resolution: RoundResolver.Resolution) {
        if let osm = resolution.osmData {
            osmCourseDataByCourse[resolution.courseId] = osm
        }
        let holes: [Hole]
        if resolution.tier == .full, let osm = resolution.osmData {
            // Build all numbered holes up front from OSM data so the round
            // opens on hole 1 with no manual prompts.
            holes = osm.holes
                .compactMap { h -> (Int, Hole)? in
                    guard let ref = h.ref, let n = Int(ref) else { return nil }
                    let coord = CLLocationCoordinate2D(
                        latitude: h.greenPoint.latitude,
                        longitude: h.greenPoint.longitude
                    )
                    return (n, Hole(number: n, coordinate: coord, par: h.par))
                }
                .sorted { $0.0 < $1.0 }
                .map { $0.1 }
        } else {
            // Partial / none: start with one empty hole, user advances manually
            holes = [Hole(number: 1)]
        }

        let newRound = Round(
            courseId: resolution.courseId,
            courseName: resolution.courseName,
            holes: holes
        )
        currentRound = newRound
        saveRound()
        WatchConnectivityManager.shared.sendRound(newRound)
        dprint("⌚ [WatchDataStore] Started round at \(resolution.courseName) (tier=\(resolution.tier), \(holes.count) holes)")
    }

    /// Legacy quick-start path — used when GPS is unavailable, no POIs found,
    /// or user cancels the picker. Identical to the old startQuickRound.
    func startManualQuickRound() {
        let quickStartCourseId = UUID()
        let firstHole = Hole(number: 1)
        let newRound = Round(
            courseId: quickStartCourseId,
            courseName: "Quick Start",
            holes: [firstHole]
        )
        currentRound = newRound
        saveRound()
        WatchConnectivityManager.shared.sendRound(newRound)
        dprint("⌚ [WatchDataStore] Started manual Quick Start round with hole 1")
    }

    /// Kept for source compatibility with any callers still referencing it.
    func startQuickRound() { startRoundAtCurrentLocation() }

    /// Maps a resolver step to a short user-facing string for the watch UI.
    private static func statusString(for step: RoundResolver.Step) -> String? {
        switch step {
        case .locating: return "Locating…"
        case .searchingPOIs: return "Searching nearby courses…"
        case .checkingDB: return "Checking saved courses…"
        case .picking: return "Pick a course"
        case .loadingCourseData(let name): return "\(name) — loading…"
        case .ready: return nil
        case .failed(let msg): return msg
        }
    }

    // MARK: - Helpers

    func filteredGreenCandidates(for courseId: UUID?) -> [HoleDetectionBlob] {
        guard let courseId,
              let detectionData = holeDetectionDataByCourse[courseId] else { return [] }

        return detectionData.blobs.filter { $0.passesFilter(holeFilterSettings) }
    }

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

    // Club types excluded from prediction entirely
    static let excludedFromPrediction: Set<String> = ["Sand"]

    // Naive mode default distances (in yards) - used when clubType.averageDistance is nil
    private let naiveDistances: [String: Int] = [
        "Drive": 245,
        "3-Wood": 225,
        "5-Wood": 207,
        "4-Hyb": 192,
        "5-Hyb": 180,
        "4-Iron": 170,
        "5-Iron": 160,
        "6-Iron": 150,
        "7-Iron": 140,
        "8-Iron": 130,
        "9-Iron": 118,
        "Pitch": 106,
        "Gap": 93,
        "Lob": 45,
        "Putt": 10
    ]

    private init() {}

    /// Get the average distance for a club type based on mode and custom settings
    func getAverage(for clubType: ClubTypeData, mode: ClubPredictionMode, customAverages: [String: Int]) -> Int {
        switch mode {
        case .naive, .smart:
            return clubType.averageDistance ?? naiveDistances[clubType.name] ?? 100
        case .manual:
            return customAverages[clubType.name] ?? clubType.averageDistance ?? naiveDistances[clubType.name] ?? 100
        case .off:
            return clubType.averageDistance ?? naiveDistances[clubType.name] ?? 100
        }
    }

    /// Find the best club index for a given distance
    func predictClubIndex(forDistance yards: Int, clubs: [ClubData], clubTypes: [ClubTypeData], mode: ClubPredictionMode, customAverages: [String: Int] = [:], disabledClubs: Set<String> = []) -> Int? {
        guard mode != .off, !clubs.isEmpty else { return nil }

        var clubDistances: [(index: Int, average: Int, name: String)] = []

        for (index, club) in clubs.enumerated() {
            guard let clubType = clubTypes.first(where: { $0.id == club.clubTypeId }) else { continue }
            guard !Self.excludedFromPrediction.contains(clubType.name) else { continue }
            guard !disabledClubs.contains(clubType.name) else { continue }

            let average = getAverage(for: clubType, mode: mode, customAverages: customAverages)
            clubDistances.append((index, average, clubType.name))
        }

        guard !clubDistances.isEmpty else { return nil }

        let closest = clubDistances.min { abs($0.average - yards) < abs($1.average - yards) }
        return closest?.index
    }
}
