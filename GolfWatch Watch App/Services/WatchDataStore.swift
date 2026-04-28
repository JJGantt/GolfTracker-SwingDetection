import Foundation
import Combine
import CoreLocation
import SwiftData

// MARK: - Club Prediction Mode

enum ClubPredictionMode: String, Codable, CaseIterable {
    case off = "Off"
    case naive = "Naive"
    case smart = "Smart"
    case manual = "Manual"
}

/// Watch-side data manager. SwiftData ModelContext is the persistence layer;
/// `currentRoundId` tracks which round the play UI is bound to. Round/Stroke
/// sync to/from the iPhone now goes through the DB (Realtime + SDK), not WC.
class WatchDataStore: ObservableObject {
    static let shared = WatchDataStore()

    /// Set at app startup via `configure(container:)`.
    private(set) var modelContainer: ModelContainer?
    /// A dedicated context for singleton-driven mutations. Separate from the
    /// view-layer mainContext so we don't need to be @MainActor-isolated.
    private var context: ModelContext? {
        guard let modelContainer = modelContainer else { return nil }
        return ModelContext(modelContainer)
    }

    /// Drives the active round screen. View layer can also use @Query for
    /// reactive updates; this @Published keeps the singleton-driven helpers
    /// (addStroke, navigateToNextHole, etc.) functional.
    @Published var currentRoundId: UUID? {
        didSet {
            objectWillChange.send()
            // Apply test-mode flag from the new round (if any).
            let enabled = currentRound?.locationTestModeEnabled == true
            LocationManager.shared.setTestModeEnabled(enabled)
        }
    }

    @Published var holeDetectionDataByCourse: [UUID: CourseHoleDetectionData] = [:]
    /// In-memory cache of OSM course data keyed by courseId. Populated when the
    /// resolver completes; consumed by AutoAdvanceMonitor's visited-green check.
    @Published var osmCourseDataByCourse: [UUID: OSMCourseData] = [:]
    @Published var holeFilterSettings: HoleDetectionFilterSettings = .default {
        didSet {
            if let data = try? JSONEncoder().encode(holeFilterSettings) {
                UserDefaults.standard.set(data, forKey: holeFilterSettingsKey)
            }
        }
    }

    /// Streamed during round start ("Locating…", "Pebble Beach — loading…").
    @Published var roundStartStatus: String?
    @Published var pendingPOIPicker: [RoundResolver.POICandidate]?
    private var pendingPOIPickerCompletion: ((RoundResolver.POICandidate?) -> Void)?

    @Published var clubPredictionMode: ClubPredictionMode = .manual {
        didSet { UserDefaults.standard.set(clubPredictionMode.rawValue, forKey: "clubPredictionMode") }
    }

    @Published var customClubAverages: [String: Int] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(customClubAverages) {
                UserDefaults.standard.set(data, forKey: "customClubAverages")
            }
        }
    }

    @Published var disabledPredictionClubs: Set<String> = [] {
        didSet {
            if let data = try? JSONEncoder().encode(Array(disabledPredictionClubs)) {
                UserDefaults.standard.set(data, forKey: "disabledPredictionClubs")
            }
        }
    }

    private let connectivity = WatchConnectivityManager.shared
    private let holeDetectionDataKey = "holeDetectionDataByCourse"
    private let holeFilterSettingsKey = "holeFilterSettings"
    private let currentRoundIdKey = "currentRoundId"

    private init() {
        loadUserDefaults()
        setupConnectivity()
        // Touch the auto-advance monitor so its location subscription wires up
        // immediately at app launch.
        _ = AutoAdvanceMonitor.shared
    }

    /// Called from GolfWatchApp at startup.
    func configure(container: ModelContainer) {
        self.modelContainer = container
        // Restore the last-active round id (the round itself was persisted by
        // SwiftData; we just need to point at it again).
        if let stored = UserDefaults.standard.string(forKey: currentRoundIdKey),
           let id = UUID(uuidString: stored) {
            currentRoundId = id
        }
    }

    // MARK: - Current Round / Hole

    var currentRound: Round? {
        guard let id = currentRoundId, let context = context else { return nil }
        let descriptor = FetchDescriptor<Round>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(descriptor))?.first
    }

    var currentHoleIndex: Int { currentRound?.currentHoleIndex ?? 0 }

    var currentHole: Hole? {
        guard let round = currentRound else { return nil }
        let sortedHoles = round.holes.sorted { $0.number < $1.number }
        guard currentHoleIndex < sortedHoles.count else { return nil }
        return sortedHoles[currentHoleIndex]
    }

    var availableClubs: [ClubData] {
        guard let context = context else { return [] }
        return (try? context.fetch(FetchDescriptor<ClubData>())) ?? []
    }

    var clubTypes: [ClubTypeData] {
        guard let context = context else { return [] }
        return (try? context.fetch(FetchDescriptor<ClubTypeData>())) ?? []
    }

    // MARK: - Stroke Management

    @discardableResult
    func addStroke(clubId: UUID, trajectoryHeading: Double? = nil, coordinate: CLLocationCoordinate2D? = nil, isPenalty: Bool = false) -> UUID? {
        guard let round = currentRound, let context = context else { return nil }
        guard let strokeCoordinate = coordinate ?? LocationManager.shared.location?.coordinate else { return nil }

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
        context.insert(stroke)
        round.strokes.append(stroke)
        try? context.save()

        // Push to Supabase via the shared sync layer.
        SupabaseSync.shared.upsertStroke(stroke, roundId: round.id)
        objectWillChange.send()
        return stroke.id
    }

    func updateStrokeClub(strokeId: UUID, clubId: UUID) {
        guard let round = currentRound, let context = context else { return }
        guard let stroke = round.strokes.first(where: { $0.id == strokeId }) else { return }
        stroke.clubId = clubId
        try? context.save()
        SupabaseSync.shared.upsertStroke(stroke, roundId: round.id)
        objectWillChange.send()
    }

    // MARK: - Round State Management

    func updateCurrentHoleIndex(newIndex: Int) {
        guard let round = currentRound, let context = context else { return }
        round.currentHoleIndex = newIndex
        try? context.save()
        SupabaseSync.shared.upsertRound(round)
        objectWillChange.send()
    }

    func completeHole(holeNumber: Int) {
        guard let round = currentRound, let context = context else { return }
        var set = round.completedHoles
        set.insert(holeNumber)
        round.completedHoles = set
        try? context.save()
        SupabaseSync.shared.upsertRound(round)
        objectWillChange.send()
    }

    func reopenHole(holeNumber: Int) {
        guard let round = currentRound, let context = context else { return }
        var set = round.completedHoles
        set.remove(holeNumber)
        round.completedHoles = set
        try? context.save()
        SupabaseSync.shared.upsertRound(round)
        objectWillChange.send()
    }

    func deleteLastStroke() {
        guard let round = currentRound, let context = context else { return }

        let hole = currentHole
        let strokesForHole = hole.map { h in round.strokes.filter { $0.holeNumber == h.number } } ?? []

        // If current hole is finished, reopen it (don't delete strokes or move back).
        if let hole = hole, round.isHoleCompleted(hole.number) {
            reopenHole(holeNumber: hole.number)
            return
        }

        // If there are strokes on current hole, delete the last one.
        if let lastStroke = strokesForHole.sorted(by: { $0.strokeNumber < $1.strokeNumber }).last {
            let strokeId = lastStroke.id
            context.delete(lastStroke)
            try? context.save()
            SupabaseSync.shared.deleteStroke(id: strokeId)
            objectWillChange.send()
        } else if currentHoleIndex > 0 {
            // No strokes on current hole — check if we just finished the previous hole.
            let sortedHoles = round.holes.sorted { $0.number < $1.number }
            let previousHoleIdx = currentHoleIndex - 1
            let previousHoleNumber = sortedHoles[previousHoleIdx].number
            if round.isHoleCompleted(previousHoleNumber) {
                reopenHole(holeNumber: previousHoleNumber)
                updateCurrentHoleIndex(newIndex: previousHoleIdx)
            }
        }
    }

    // MARK: - Connectivity Setup

    private func setupConnectivity() {
        connectivity.onReceiveHoleDetectionData = { [weak self] detectionData in
            DispatchQueue.main.async {
                self?.holeDetectionDataByCourse[detectionData.courseId] = detectionData
            }
        }
        // Watch is the authority for filter settings — push current value to iPhone on launch.
        connectivity.sendHoleFilterSettings(holeFilterSettings)
    }

    // MARK: - UserDefaults persistence (small, non-relational state)

    private func loadUserDefaults() {
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
        guard let hole = currentHole, let round = currentRound else { return }
        completeHole(holeNumber: hole.number)
        if currentHoleIndex < round.holes.count - 1 {
            updateCurrentHoleIndex(newIndex: currentHoleIndex + 1)
        }
    }

    func isHoleCompleted(_ holeNumber: Int) -> Bool {
        currentRound?.isHoleCompleted(holeNumber) ?? false
    }

    // MARK: - Hole Management

    func addNextHole() {
        guard let round = currentRound, let context = context else { return }
        let nextHoleNumber = round.holes.count + 1
        let newHole = Hole(number: nextHoleNumber)
        context.insert(newHole)
        round.holes.append(newHole)
        round.currentHoleIndex = nextHoleNumber - 1
        try? context.save()
        SupabaseSync.shared.upsertRound(round)
        AutoAdvanceMonitor.shared.resetForCurrentHole()
        objectWillChange.send()
    }

    func addHole(coordinate: CLLocationCoordinate2D, par: Int? = nil) {
        guard let round = currentRound, let context = context else { return }
        let nextHoleNumber = round.holes.count + 1
        let newHole = Hole(number: nextHoleNumber, coordinate: coordinate, par: par)
        context.insert(newHole)
        round.holes.append(newHole)
        round.currentHoleIndex = nextHoleNumber - 1
        try? context.save()
        SupabaseSync.shared.upsertRound(round)
        AutoAdvanceMonitor.shared.resetForCurrentHole()
        objectWillChange.send()
    }

    func updateHole(holeNumber: Int, newCoordinate: CLLocationCoordinate2D, par: Int? = nil) {
        guard let round = currentRound, let context = context else { return }
        guard let hole = round.holes.first(where: { $0.number == holeNumber }) else { return }
        hole.latitude = newCoordinate.latitude
        hole.longitude = newCoordinate.longitude
        if let par = par { hole.par = par }
        try? context.save()
        SupabaseSync.shared.upsertRound(round)
        objectWillChange.send()
    }

    func navigateToNextHole() {
        guard let round = currentRound else { return }
        let nextIndex = currentHoleIndex + 1
        guard nextIndex < round.holes.count else { return }
        updateCurrentHoleIndex(newIndex: nextIndex)
    }

    func navigateToPreviousHole() {
        let prevIndex = currentHoleIndex - 1
        guard prevIndex >= 0 else { return }
        updateCurrentHoleIndex(newIndex: prevIndex)
        AutoAdvanceMonitor.shared.resetForCurrentHole()
    }

    // MARK: - Start Round (resolver-backed)

    func startRoundAtCurrentLocation() {
        let coordinate: CLLocationCoordinate2D
        if let loc = LocationManager.shared.location?.coordinate {
            coordinate = loc
        } else {
            startManualQuickRound()
            return
        }
        roundStartStatus = "Locating…"
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

    func pickPOICandidate(_ candidate: RoundResolver.POICandidate?) {
        let cb = pendingPOIPickerCompletion
        pendingPOIPicker = nil
        pendingPOIPickerCompletion = nil
        cb?(candidate)
    }

    private func startRound(from resolution: RoundResolver.Resolution) {
        guard let context = context else { return }
        if let osm = resolution.osmData {
            osmCourseDataByCourse[resolution.courseId] = osm
        }

        let holes: [Hole]
        if resolution.tier == .full, let osm = resolution.osmData {
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
            holes = [Hole(number: 1)]
        }

        let newRound = Round(
            courseId: resolution.courseId,
            courseName: resolution.courseName,
            holes: holes
        )
        for h in holes { context.insert(h) }
        context.insert(newRound)
        try? context.save()
        currentRoundId = newRound.id
        UserDefaults.standard.set(newRound.id.uuidString, forKey: currentRoundIdKey)
        SupabaseSync.shared.upsertRound(newRound)
        dprint("⌚ [WatchDataStore] Started round at \(resolution.courseName) (tier=\(resolution.tier), \(holes.count) holes)")
    }

    func startManualQuickRound() {
        guard let context = context else { return }
        let firstHole = Hole(number: 1)
        let newRound = Round(
            courseId: UUID(),
            courseName: "Quick Start",
            holes: [firstHole]
        )
        context.insert(firstHole)
        context.insert(newRound)
        try? context.save()
        currentRoundId = newRound.id
        UserDefaults.standard.set(newRound.id.uuidString, forKey: currentRoundIdKey)
        SupabaseSync.shared.upsertRound(newRound)
    }

    func startQuickRound() { startRoundAtCurrentLocation() }

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

    func osmCourseData(forCourseId id: UUID) -> OSMCourseData? {
        osmCourseDataByCourse[id]
    }

    func replaceTargets(forHoleNumber holeNumber: Int?, with coordinates: [CLLocationCoordinate2D]) {
        guard let holeNumber = holeNumber,
              let round = currentRound,
              let context = context else { return }
        // Remove old targets for this hole
        let toDelete = round.targets.filter { $0.holeNumber == holeNumber }
        for target in toDelete {
            context.delete(target)
            SupabaseSync.shared.deleteTarget(id: target.id)
        }
        // Add new targets
        for coord in coordinates {
            let t = Target(holeNumber: holeNumber, coordinate: coord)
            context.insert(t)
            round.targets.append(t)
            SupabaseSync.shared.upsertTarget(t, roundId: round.id)
        }
        try? context.save()
        objectWillChange.send()
    }

    func filteredGreenCandidates(for courseId: UUID?) -> [HoleDetectionBlob] {
        guard let courseId,
              let detectionData = holeDetectionDataByCourse[courseId] else { return [] }
        return detectionData.blobs.filter { $0.passesFilter(holeFilterSettings) }
    }

    func strokeCount(for hole: Hole) -> Int {
        currentRound?.strokes.filter { $0.holeNumber == hole.number }.count ?? 0
    }

    func getClub(byId id: UUID) -> ClubData? {
        availableClubs.first { $0.id == id }
    }

    func getClubType(byId id: UUID) -> ClubTypeData? {
        clubTypes.first { $0.id == id }
    }

    func getTypeName(for club: ClubData) -> String {
        clubTypes.first { $0.id == club.clubTypeId }?.name ?? club.name
    }
}

// MARK: - Club Prediction Manager

class ClubPredictionManager {
    static let shared = ClubPredictionManager()

    static let excludedFromPrediction: Set<String> = ["Sand"]

    private let naiveDistances: [String: Int] = [
        "Drive": 245, "3-Wood": 225, "5-Wood": 207,
        "4-Hyb": 192, "5-Hyb": 180,
        "4-Iron": 170, "5-Iron": 160, "6-Iron": 150, "7-Iron": 140, "8-Iron": 130, "9-Iron": 118,
        "Pitch": 106, "Gap": 93, "Lob": 45, "Putt": 10
    ]

    private init() {}

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
