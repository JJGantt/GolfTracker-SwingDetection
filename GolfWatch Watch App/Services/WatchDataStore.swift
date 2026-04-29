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
    /// Single shared `ModelContext` for the lifetime of this singleton.
    /// **Do not** create a fresh context per access — fresh contexts have
    /// known cross-context cache-coherence issues with SwiftData where a
    /// save in one context isn't immediately visible to fetches in another
    /// (we hit a 21s stale-read bug doing it that way; see commit history).
    /// Using one shared context for all reads + mutations keeps things
    /// internally consistent and matches SwiftData best practice.
    private var sharedContext: ModelContext?
    private var context: ModelContext? { sharedContext }
    /// Public read-only accessor so `RealtimeSync` can apply postgres-changes
    /// echoes into the SAME context our local mutations use. Cross-context
    /// would re-introduce the stale-read bug.
    var modelContext: ModelContext? { sharedContext }

    /// Drives the active round screen. **Now derived** from the rounds in
    /// SwiftData (most recent round started within `currentRoundMaxAgeSeconds`)
    /// rather than being explicitly written by start/resume code paths. This
    /// makes "current round" a global concept across phone + watch — a round
    /// inserted via Realtime sync from the phone immediately appears as
    /// current on the watch (and vice versa) without any explicit handoff.
    /// `refreshCurrentRound()` re-evaluates the query and updates this id.
    @Published private(set) var currentRoundId: UUID? {
        didSet {
            guard currentRoundId != oldValue else { return }
            // Apply test-mode flag from the new round (if any). Same side
            // effect as before; just fired from refreshCurrentRound() now
            // instead of from explicit currentRoundId writes.
            let enabled = currentRound?.locationTestModeEnabled == true
            LocationManager.shared.setTestModeEnabled(enabled)
        }
    }

    /// Mirror of `DataStore.currentRoundMaxAgeSeconds` — both platforms use
    /// the same 8h window for "what counts as current."
    static let currentRoundMaxAgeSeconds: TimeInterval = 8 * 60 * 60

    /// Re-evaluate which round (if any) is "current" based on what's in
    /// SwiftData right now. Call after any code path that mutates rounds:
    /// local start/resume, addHole, updateHole, etc., and from
    /// RealtimeSync after an inbound `rounds` postgres-changes event.
    func refreshCurrentRound() {
        guard let context = context else { return }
        let cutoff = Date().addingTimeInterval(-Self.currentRoundMaxAgeSeconds)
        let descriptor = FetchDescriptor<Round>(
            sortBy: [SortDescriptor(\Round.date, order: .reverse)]
        )
        let rounds = (try? context.fetch(descriptor)) ?? []
        let mostRecent = rounds.first { $0.date >= cutoff }
        let newId = mostRecent?.id
        if newId != currentRoundId { currentRoundId = newId }
    }

    @Published var holeDetectionDataByCourse: [UUID: CourseHoleDetectionData] = [:]
    /// In-memory cache of OSM course data keyed by courseId. Populated when the
    /// resolver completes; consumed by AutoAdvanceMonitor's visited-green check.
    @Published var osmCourseDataByCourse: [UUID: OSMCourseData] = [:]
    /// The user's assigned palette color in their current playgroup. Persists
    /// across devices because it's read from `playgroup_members.color` (set
    /// once at host/join time and stored in Supabase). Defaults to blue when
    /// the user isn't in a playgroup. Used to tint the user's own GPS arrow
    /// on the active round map and their own row/dot in scorecard + member
    /// lists, so the user can see at-a-glance "I'm blue" and reference that
    /// when talking to other players in the group.
    @Published var myPlayerColor: String = PlaygroupService.playerPalette[0]

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

    /// Set when the resolver finds exactly one nearby saved course and needs
    /// the user to confirm "Play <name>?" or "Different course".
    @Published var pendingExistingCoursePrompt: RoundResolver.ExistingCourseMatch?
    private var pendingExistingCourseCompletion: ((Bool) -> Void)?

    /// Set after the resolver completes with GolfCourseAPI scorecard data —
    /// the user picks a tee from the cached tee list before the round opens.
    @Published var pendingTeePicker: PendingTeePicker?
    /// Holds the resolution while the tee picker is up, so we can start the
    /// round once the user picks (or skips).
    private var pendingTeePickerResolution: RoundResolver.Resolution?

    struct PendingTeePicker {
        let courseName: String
        let tees: [CachedCourseTee]
    }

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
    // currentRoundIdKey was the UserDefaults key for the old explicit
    // currentRoundId persistence; no longer used (the SwiftData store is
    // the source of truth, refreshCurrentRound queries it).

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
        self.sharedContext = ModelContext(container)
        // Prime the clubs cache from whatever SwiftData has on disk; the
        // hydrate path will refresh it again once Supabase responds.
        refreshClubsCache()
        // Derive currentRoundId from whatever's in SwiftData (most recent
        // round started within the 8h window). Replaces the old UserDefaults
        // persistence — the query is the source of truth, and SwiftData
        // already persists rounds across launches.
        refreshCurrentRound()
        // Pick up our playgroup-assigned color (if any) so the GPS arrow renders
        // correctly on first launch even before the user opens MultiplayerView.
        refreshMyPlayerColor()
        // Pull clubs/club_types/club_sets from the DB so the watch isn't
        // stuck on the "Waiting for clubs to sync..." screen between rounds.
        // RealtimeSync is round-scoped (intentional — keeps the WebSocket off
        // when idle), so without an explicit hydrate path the watch never
        // sees iPhone-side club edits unless the user enters a round.
        hydrateClubsFromSupabase()
        // Auth may not be ready at app launch (session arrives via WC from
        // iPhone). Re-hydrate the moment we have a valid user.
        WatchAuthSession.shared.onSessionChanged = { [weak self] session in
            if session != nil { self?.hydrateClubsFromSupabase() }
        }
    }

    /// One-shot fetch of the user's clubs/club_types/club_sets from Supabase
    /// into local SwiftData. Idempotent — upserts by id, doesn't delete.
    /// Called from `configure(container:)` at launch and from
    /// `WatchHomeView.onAppear` so iPhone-side edits between rounds catch up.
    func hydrateClubsFromSupabase() {
        Task { [weak self] in
            guard let self = self else { return }
            guard let context = self.context else { return }
            guard WatchAuthSession.shared.currentUserId != nil else { return }
            let supabase = SupabaseManager.shared
            do {
                async let typesAsync: [ClubTypeDTO] = supabase.from("club_types").select().execute().value
                async let clubsAsync: [ClubDTO] = supabase.from("clubs").select().execute().value
                async let setsAsync: [ClubSetDTO] = supabase.from("club_sets").select().execute().value
                let (types, clubs, sets) = try await (typesAsync, clubsAsync, setsAsync)
                await MainActor.run {
                    // Supabase is the source of truth for clubs/types/sets
                    // on the watch. Insert/update for everything we just
                    // fetched, then DELETE any local row whose id isn't in
                    // the fetched set. Without this, leftover rows from
                    // earlier app versions (pre-Supabase-sync) accumulate
                    // alongside the synced ones, producing duplicates.
                    let fetchedTypeIds = Set(types.map(\.id))
                    let fetchedClubIds = Set(clubs.map(\.id))
                    let fetchedSetIds  = Set(sets.map(\.id))

                    for t in types { Self.upsertClubType(t, into: context) }
                    for c in clubs { Self.upsertClub(c, into: context) }
                    for s in sets { Self.upsertClubSet(s, into: context) }

                    // Prune local-only entries.
                    if let existingTypes = try? context.fetch(FetchDescriptor<ClubTypeData>()) {
                        for t in existingTypes where !fetchedTypeIds.contains(t.id) {
                            context.delete(t)
                        }
                    }
                    if let existingClubs = try? context.fetch(FetchDescriptor<ClubData>()) {
                        for c in existingClubs where !fetchedClubIds.contains(c.id) {
                            context.delete(c)
                        }
                    }
                    if let existingSets = try? context.fetch(FetchDescriptor<ClubSet>()) {
                        for s in existingSets where !fetchedSetIds.contains(s.id) {
                            context.delete(s)
                        }
                    }

                    try? context.save()
                    // Republish the cached arrays so views pick up new clubs.
                    self.refreshClubsCache()
                    self.objectWillChange.send()
                    dprint("⌚ [WatchDataStore] hydrated \(types.count) types / \(clubs.count) clubs / \(sets.count) sets (pruned local-only rows)")
                }
            } catch {
                dprint("⌚ [WatchDataStore] hydrate failed: \(error.localizedDescription)")
            }
        }
    }

    private static func upsertClubType(_ t: ClubTypeDTO, into context: ModelContext) {
        let id = t.id
        let descriptor = FetchDescriptor<ClubTypeData>(predicate: #Predicate { $0.id == id })
        if let existing = (try? context.fetch(descriptor))?.first {
            existing.name = t.name
            existing.isDefault = t.is_default ?? false
            existing.averageDistance = t.average_distance
        } else {
            context.insert(ClubTypeData(id: id, name: t.name, isDefault: t.is_default ?? false, averageDistance: t.average_distance))
        }
    }

    private static func upsertClub(_ c: ClubDTO, into context: ModelContext) {
        let id = c.id
        let descriptor = FetchDescriptor<ClubData>(predicate: #Predicate { $0.id == id })
        if let existing = (try? context.fetch(descriptor))?.first {
            existing.name = c.name
            existing.clubTypeId = c.club_type_id
            existing.isDefault = c.is_default ?? false
        } else {
            context.insert(ClubData(id: id, name: c.name, clubTypeId: c.club_type_id, isDefault: c.is_default ?? false))
        }
    }

    private static func upsertClubSet(_ s: ClubSetDTO, into context: ModelContext) {
        let id = s.id
        let descriptor = FetchDescriptor<ClubSet>(predicate: #Predicate { $0.id == id })
        let dc = s.date_created.flatMap(Self.parseISO) ?? Date()
        let dm = s.date_modified.flatMap(Self.parseISO) ?? Date()
        if let existing = (try? context.fetch(descriptor))?.first {
            existing.name = s.name
            existing.isActive = s.is_active ?? false
            existing.dateCreated = dc
            existing.dateModified = dm
        } else {
            context.insert(ClubSet(id: id, name: s.name, typeSelections: [], isActive: s.is_active ?? false, dateCreated: dc, dateModified: dm))
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static func parseISO(_ s: String) -> Date? {
        if let d = isoFormatter.date(from: s) { return d }
        let alt = ISO8601DateFormatter(); alt.formatOptions = [.withInternetDateTime]
        return alt.date(from: s)
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

    /// Cached snapshot of `ClubData` rows. Re-fetching from SwiftData on
    /// every access (the previous pattern) was producing a fresh array
    /// per call, which made SwiftUI unable to memoize anything downstream
    /// of `clubs` — every body evaluation looked like new data and forced
    /// re-renders of the club picker, swing detector club hookup, etc.
    /// At ~5 body evals/sec from heading updates, that was the dominant
    /// cause of digital-crown lag. Now we cache the list and refresh it
    /// only on actual mutations.
    @Published private(set) var availableClubs: [ClubData] = []
    @Published private(set) var clubTypes: [ClubTypeData] = []
    @Published private(set) var clubSets: [ClubSet] = []

    /// Clubs of the active ClubSet, in type order. This is what the
    /// watch crown should scroll through during a round — NOT the full
    /// `availableClubs` catalog (which can have multiple clubs per type
    /// when the user owns alternates). Falls back to `availableClubs` when
    /// no active set exists yet (shouldn't happen post-seed, but safe).
    var activeSetClubs: [ClubData] {
        guard let activeSet = clubSets.first(where: { $0.isActive }) else {
            return availableClubs
        }
        // Order: follow the type order from clubTypes (Drive → Putt) rather
        // than typeSelections' internal order, so the crown has a stable,
        // predictable progression.
        let typeOrder = clubTypes.map(\.id)
        let selectionsByType = Dictionary(uniqueKeysWithValues:
            activeSet.typeSelections.map { ($0.typeId, $0.activeClubId) }
        )
        return typeOrder.compactMap { typeId in
            guard let activeClubId = selectionsByType[typeId] ?? nil else { return nil }
            return availableClubs.first { $0.id == activeClubId }
        }
    }

    /// Re-pull the cached clubs/types/sets arrays from SwiftData. Call
    /// after any local mutation that could change them (hydrate, insert,
    /// delete, set switch).
    func refreshClubsCache() {
        guard let context = context else { return }
        let fetchedClubs = (try? context.fetch(FetchDescriptor<ClubData>())) ?? []
        let fetchedTypes = (try? context.fetch(FetchDescriptor<ClubTypeData>())) ?? []
        let fetchedSets  = (try? context.fetch(FetchDescriptor<ClubSet>())) ?? []
        // Avoid redundant publishes — comparing ids covers the common case
        // (re-publish only when the set of ids actually changed).
        let newClubIds = fetchedClubs.map(\.id)
        let oldClubIds = availableClubs.map(\.id)
        if newClubIds != oldClubIds { availableClubs = fetchedClubs }
        let newTypeIds = fetchedTypes.map(\.id)
        let oldTypeIds = clubTypes.map(\.id)
        if newTypeIds != oldTypeIds { clubTypes = fetchedTypes }
        // Sets need a deeper compare — switching active set keeps ids the
        // same but changes isActive. Compare ids + active flag.
        let newSetSig = fetchedSets.map { "\($0.id)-\($0.isActive)" }
        let oldSetSig = clubSets.map { "\($0.id)-\($0.isActive)" }
        if newSetSig != oldSetSig { clubSets = fetchedSets }
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
        ClientEventLogger.log("addNextHole.start")
        guard let round = currentRound, let context = context else {
            ClientEventLogger.log("addNextHole.guardFailed")
            return
        }
        let nextHoleNumber = round.holes.count + 1
        let newHole = Hole(number: nextHoleNumber)
        context.insert(newHole)
        round.holes.append(newHole)
        round.currentHoleIndex = nextHoleNumber - 1
        try? context.save()
        ClientEventLogger.log("addNextHole.saved", detail: ["holeNumber": .integer(nextHoleNumber), "holeCount": .integer(round.holes.count)])
        SupabaseSync.shared.upsertRound(round)
        ClientEventLogger.log("addNextHole.upsertEnqueued")
        AutoAdvanceMonitor.shared.resetForCurrentHole()
        objectWillChange.send()
        ClientEventLogger.log("addNextHole.objectWillChangeSent")
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
        ClientEventLogger.log("updateHole.start", detail: ["holeNumber": .integer(holeNumber), "par": par.map { .integer($0) } ?? .null])
        guard let round = currentRound, let context = context else {
            ClientEventLogger.log("updateHole.guardFailed.round")
            return
        }
        guard let hole = round.holes.first(where: { $0.number == holeNumber }) else {
            ClientEventLogger.log("updateHole.guardFailed.hole")
            return
        }
        hole.latitude = newCoordinate.latitude
        hole.longitude = newCoordinate.longitude
        if let par = par { hole.par = par }
        try? context.save()
        ClientEventLogger.log("updateHole.saved")
        SupabaseSync.shared.upsertRound(round)
        ClientEventLogger.log("updateHole.upsertEnqueued")
        objectWillChange.send()
        ClientEventLogger.log("updateHole.objectWillChangeSent")
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
            existingCoursePrompt: { [weak self] match, choose in
                DispatchQueue.main.async {
                    self?.pendingExistingCoursePrompt = match
                    self?.pendingExistingCourseCompletion = choose
                }
            },
            completion: { [weak self] resolution in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.roundStartStatus = nil
                    if let resolution = resolution {
                        self.handleResolved(resolution)
                    } else {
                        self.startManualQuickRound()
                    }
                }
            }
        )
    }

    /// Bridge between resolver completion and round start. If GolfCourseAPI
    /// returned scorecard data, present the tee picker first; otherwise start
    /// the round immediately with no tee selection.
    private func handleResolved(_ resolution: RoundResolver.Resolution) {
        guard let scorecard = resolution.scorecardCourse else {
            startRound(from: resolution, selectedTeeId: nil)
            return
        }
        // Pull cached tees from DB (the Edge Function populated them as a side
        // effect of the search call during resolveScorecard).
        Task { [weak self] in
            do {
                let tees = try await GolfCourseAPIService.shared.cachedTees(
                    forExternalCourseId: String(scorecard.id)
                )
                await MainActor.run {
                    guard let self = self else { return }
                    if tees.isEmpty {
                        // Cache miss (rare — Edge Function should have written
                        // them). Skip picker, start round with no tee.
                        self.startRound(from: resolution, selectedTeeId: nil)
                    } else {
                        self.pendingTeePickerResolution = resolution
                        self.pendingTeePicker = PendingTeePicker(
                            courseName: resolution.courseName,
                            tees: tees
                        )
                    }
                }
            } catch {
                dprint("⌚ [WatchDataStore] tee fetch failed: \(error.localizedDescription) — starting without tee")
                await MainActor.run {
                    self?.startRound(from: resolution, selectedTeeId: nil)
                }
            }
        }
    }

    /// Called by the watch's tee picker UI. `nil` = user cancelled / no tee
    /// (round still starts).
    func pickTee(_ tee: CachedCourseTee?) {
        let resolution = pendingTeePickerResolution
        pendingTeePicker = nil
        pendingTeePickerResolution = nil
        guard let resolution = resolution else { return }
        startRound(from: resolution, selectedTeeId: tee?.id)
    }

    func pickPOICandidate(_ candidate: RoundResolver.POICandidate?) {
        let cb = pendingPOIPickerCompletion
        pendingPOIPicker = nil
        pendingPOIPickerCompletion = nil
        cb?(candidate)
    }

    /// Called by the home view's "Play <course>?" prompt. `confirmed=true`
    /// → resolver fast-paths to the existing course; false → falls through
    /// to OSM resolution.
    func answerExistingCoursePrompt(confirmed: Bool) {
        let cb = pendingExistingCourseCompletion
        pendingExistingCoursePrompt = nil
        pendingExistingCourseCompletion = nil
        cb?(confirmed)
    }

    private func startRound(from resolution: RoundResolver.Resolution, selectedTeeId: UUID?) {
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
                    return (n, Hole(number: n, coordinate: coord, par: h.par, teeId: selectedTeeId))
                }
                .sorted { $0.0 < $1.0 }
                .map { $0.1 }
        } else {
            holes = [Hole(number: 1, teeId: selectedTeeId)]
        }

        let newRound = Round(
            courseId: resolution.courseId,
            courseName: resolution.courseName,
            holes: holes,
            selectedTeeId: selectedTeeId
        )
        for h in holes { context.insert(h) }
        context.insert(newRound)
        try? context.save()
        refreshCurrentRound()
        SupabaseSync.shared.upsertRound(newRound)
        dprint("⌚ [WatchDataStore] Started round at \(resolution.courseName) (tier=\(resolution.tier), \(holes.count) holes, tee=\(selectedTeeId?.uuidString ?? "none"))")
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
        refreshCurrentRound()
        SupabaseSync.shared.upsertRound(newRound)
    }

    func startQuickRound() { startRoundAtCurrentLocation() }

    private static func statusString(for step: RoundResolver.Step) -> String? {
        switch step {
        case .locating: return "Locating…"
        case .checkingExisting: return "Checking saved courses…"
        case .confirmingExisting(let match): return "Found \(match.courseName)"
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

    /// Refresh `myPlayerColor` from the user's current playgroup membership.
    /// Call this after host/join operations. If the user isn't in a playgroup,
    /// falls back to palette[0] so the GPS arrow stays a familiar color.
    func refreshMyPlayerColor() {
        guard let userId = WatchAuthSession.shared.currentUserId else { return }
        Task { [weak self] in
            do {
                guard let pg = try await PlaygroupService.shared.currentOpenPlaygroup() else {
                    await MainActor.run { self?.myPlayerColor = PlaygroupService.playerPalette[0] }
                    return
                }
                let members = try await PlaygroupService.shared.members(of: pg.id)
                let myRow = members.first { $0.userId == userId }
                let color = myRow?.color ?? PlaygroupService.playerPalette[0]
                await MainActor.run { self?.myPlayerColor = color }
            } catch {
                dprint("⌚ [WatchDataStore] refreshMyPlayerColor failed: \(error.localizedDescription)")
            }
        }
    }

    func replaceTargets(forHoleNumber holeNumber: Int?, with coordinates: [CLLocationCoordinate2D]) {
        ClientEventLogger.log("replaceTargets.start", detail: [
            "holeNumber": holeNumber.map { .integer($0) } ?? .null,
            "newCount": .integer(coordinates.count)
        ])
        guard let holeNumber = holeNumber,
              let round = currentRound,
              let context = context else {
            ClientEventLogger.log("replaceTargets.guardFailed")
            return
        }
        let toDelete = round.targets.filter { $0.holeNumber == holeNumber }
        ClientEventLogger.log("replaceTargets.toDelete", detail: ["count": .integer(toDelete.count)])
        for target in toDelete {
            context.delete(target)
            SupabaseSync.shared.deleteTarget(id: target.id)
        }
        for coord in coordinates {
            let t = Target(holeNumber: holeNumber, coordinate: coord)
            context.insert(t)
            round.targets.append(t)
            SupabaseSync.shared.upsertTarget(t, roundId: round.id)
        }
        try? context.save()
        ClientEventLogger.log("replaceTargets.saved", detail: ["roundTargetsCount": .integer(round.targets.count)])
        objectWillChange.send()
    }

    /// Returns the list of green candidates the user can pick from when
    /// labeling a hole. Two sources, in priority order:
    ///   1. **OSM green polygons** (when round was resolved with OSM data) —
    ///      cleaner: real polygons from mapper-curated data, no false positives
    ///      from blob detection. Used for Tier-2 rounds (greens present but
    ///      holes weren't cleanly numberable) AND as a supplement to Tier-3.
    ///   2. **Blob detection results** (Tier-3 rounds without OSM coverage) —
    ///      MapKit-pixel-derived polygons from the existing analyzer.
    /// Both kinds are returned as `HoleDetectionBlob` so the existing picker
    /// UI doesn't need to know the difference.
    func filteredGreenCandidates(for courseId: UUID?) -> [HoleDetectionBlob] {
        guard let courseId else { return [] }
        var out: [HoleDetectionBlob] = []
        if let osm = osmCourseDataByCourse[courseId] {
            out.append(contentsOf: osm.greens.map(Self.blob(fromOSMGreen:)))
        }
        if let detectionData = holeDetectionDataByCourse[courseId] {
            out.append(contentsOf: detectionData.blobs.filter { $0.passesFilter(holeFilterSettings) })
        }
        return out
    }

    /// Convert an OSM green polygon to the `HoleDetectionBlob` shape the
    /// picker UI consumes. Filter fields are set so the OSM polygon always
    /// passes (it's mapper-curated, not heuristic-detected).
    private static func blob(fromOSMGreen polygon: OSMPolygon) -> HoleDetectionBlob {
        let avgLat = polygon.points.map(\.latitude).reduce(0, +) / Double(max(polygon.points.count, 1))
        let avgLon = polygon.points.map(\.longitude).reduce(0, +) / Double(max(polygon.points.count, 1))
        return HoleDetectionBlob(
            id: UUID(),  // synthetic — OSM way ids are Int64, doesn't fit UUID
            area: 9_999,
            minWidth: 999,
            elongation: 1.0,
            greennessScore: 9_999,
            centroidLatitude: avgLat,
            centroidLongitude: avgLon,
            polygon: polygon.points
        )
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

// (ClubTypeDTO / ClubDTO / ClubSetDTO moved to Models.swift so both iOS
// and watch targets share the same wire shape.)
