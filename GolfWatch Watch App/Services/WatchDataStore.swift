import Foundation
import Combine
import CoreLocation
import SwiftData

/// Watch-side data manager. SwiftData ModelContext is the persistence layer;
/// `currentRoundId` tracks which round the play UI is bound to. Round/Stroke
/// sync to/from the iPhone now goes through the DB (Realtime + SDK), not WC.
@MainActor
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
    var context: ModelContext? { sharedContext }
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
    @Published private(set) var currentRoundId: UUID?
    // Note: this used to have a didSet that read `round.locationTestModeEnabled`
    // (a legacy per-round flag) and called `LocationManager.setTestModeEnabled`.
    // That stomped on the global test-mode state — the moment a user picked a
    // tee and the new round was set as current, location flipped to real GPS
    // because the new Round had locationTestModeEnabled=false. Global test
    // mode is now owned exclusively by `TestModeService` (writes to
    // `user_test_state`, syncs cross-device via Realtime).

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
        let mostRecent = rounds.first { $0.endedAt == nil && $0.date >= cutoff }
        let newId = mostRecent?.id
        if newId != currentRoundId { currentRoundId = newId }
        // Make sure the in-memory osm_polygons cache is populated for the
        // current round's course. The resolver populates it on a fresh
        // round-start, but resumed rounds (cold launch, mid-round app
        // restart, cross-device handoff) never go through that path —
        // without this, green detection / putter auto-switch / auto-
        // advance silently do nothing because filteredGreenCandidates
        // returns empty.
        if let courseId = mostRecent?.courseId, osmCourseDataByCourse[courseId] == nil {
            hydrateOsmDataForCourse(courseId)
        }
        // Same problem for blob detection results. Fresh round-start fetches
        // these (the polygon path puts them into holeDetectionDataByCourse),
        // but resumed rounds skip that path and `filteredGreenCandidates`
        // ends up empty — the hole has no polygon, the putter switcher
        // falls back to yardage, AutoAdvance loses its edge-distance signal.
        if let courseId = mostRecent?.courseId, holeDetectionDataByCourse[courseId] == nil {
            hydrateBlobDetectionForCourse(courseId)
        }
    }

    /// Resolved canonical green per hole_number for a course. Cached at
    /// round-start so addNextHole can read without re-querying. Resolution:
    ///   1. THIS user has a pick → use it
    ///   2. ≥3 distinct users picked AND ≥75% share the same blob_id →
    ///      that blob's centroid + modal par
    ///   3. Else nil (placement view will appear)
    /// Manual picks (blob_id == NULL) never participate in voting but
    /// satisfy rule 1 for the picker themselves.
    var canonicalHolePlacementsByCourse: [UUID: [Int: (lat: Double, lon: Double, par: Int?)]] = [:]
    @Published var holeDetectionDataByCourse: [UUID: CourseHoleDetectionData] = [:]
    /// Where a blob request to the iPhone stands. `queued`, `running` and
    /// `failed` are the phone's own reports (`HoleDetectionPhoneState`);
    /// `sent` and `unreachable` are what the watch knows before it hears back.
    enum BlobRequestStatus: Equatable {
        case sent
        case unreachable
        case queued
        case running
        case failed
    }
    /// Per course, the state of an outstanding blob request. Absent once the
    /// results are in hand (or nothing was ever asked for).
    @Published var blobRequestStatusByCourse: [UUID: BlobRequestStatus] = [:]
    /// The round-start card (`BlobRequestCard`): the course whose blobs the
    /// phone still owes. Cleared by Continue, by the results arriving, or by
    /// the round ending. Results that land after Continue are still applied —
    /// the card only decides whether the user is held at round start.
    @Published var blobPromptCourseId: UUID?
    /// In-memory cache of OSM course data keyed by courseId. Populated when the
    /// resolver completes; consumed by AutoAdvanceMonitor's visited-green check.
    @Published var osmCourseDataByCourse: [UUID: OSMCourseData] = [:]
    /// Per-hole yardage from the selected tee for the current round, keyed
    /// by hole number. Populated on round-start by fetching `course_tee_holes`
    /// for the user's chosen tee. Drives the "official" yardage display
    /// when the user hasn't yet teed off (no strokes recorded for the hole),
    /// before falling back to live GPS distance once the round is in motion.
    @Published var teeHoleYardages: [Int: Int] = [:]
    /// Per-hole par from the API scorecard for the currently-selected tee.
    /// Used to skip the par picker in HolePlacementView when known.
    @Published var teeHolePars: [Int: Int] = [:]
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
    @Published var pendingCoursePicker: [RoundResolver.CourseCandidate]?
    var pendingCoursePickerCompletion: ((RoundResolver.CourseCandidate?) -> Void)?

    /// Set after the resolver runs the GCAPI search — the user picks one of
    /// the ranked candidates OR "Course not listed" (which completes with nil
    /// → round starts without scorecard data, manual par + GPS yardage).
    @Published var pendingScorecardPicker: PendingScorecardPicker?
    var pendingScorecardPickerCompletion: ((GCAPICourse?) -> Void)?

    /// Name-this-course prompt. Set when the resolver hits the `.manual`
    /// path — nothing identified where the user is, so they name it and the
    /// course is stored at their GPS for next time. A name is REQUIRED;
    /// completing with nil cancels the round rather than falling back to a
    /// throwaway placeholder course.
    @Published var pendingCourseNamePrompt: Bool = false
    var pendingCourseNameCompletion: ((String?) -> Void)?

    /// Set after the resolver completes with GolfCourseAPI scorecard data —
    /// the user picks a tee from the cached tee list before the round opens.
    @Published var pendingTeePicker: PendingTeePicker?
    /// Holds the resolution while the tee picker is up, so we can start the
    /// round once the user picks (or skips).
    var pendingTeePickerResolution: RoundResolver.Resolution?

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

    var lifecycleTimer: Timer?

    private init() {
        loadUserDefaults()
        setupConnectivity()
        // Touch the auto-advance monitor so its location subscription wires up
        // immediately at app launch.
        _ = AutoAdvanceMonitor.shared
        startRoundLifecycleSweep()
    }

    /// Called from GolfWatchApp at startup.
    func configure(container: ModelContainer) {
        self.modelContainer = container
        let context = ModelContext(container)
        self.sharedContext = context
        // Split rounds off course holes they may still share (the watch picks
        // them up from phone-started rounds whose `round_holes` ids were the
        // course's), then bring the server's rows in line.
        SupabaseSync.shared.markRoundHolesForRewrite(context.separateRoundHolesFromCourseHoles())
        context.backfillCurrentHoleNumbers()
        Task { @MainActor in
            await SupabaseSync.shared.rewritePendingRoundHoles(context: context)
            await RealtimeSync.shared.reconcileCourseHoles()
        }
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
        // iPhone). Re-hydrate the moment we have a valid user. Also wake
        // TestModeService here — it bails early if currentUserId is nil
        // at first launch, so this is the retry hook.
        WatchAuthSession.shared.onSessionChanged = { [weak self] session in
            if session != nil {
                self?.hydrateClubsFromSupabase()
                Task { @MainActor in TestModeService.shared.start() }
            }
        }
    }

    /// One-shot fetch of the user's clubs/club_types/club_sets from Supabase
    /// into local SwiftData. Idempotent — upserts by id, doesn't delete.
    /// Called from `configure(container:)` at launch and from
    /// `WatchHomeView.onAppear` so iPhone-side edits between rounds catch up.
    // MARK: - Current Round / Hole

    /// Cache backing `currentRound`. SwiftData @Model classes are reference
    /// types, so a stored reference stays current even when the underlying
    /// row is mutated from elsewhere (RealtimeSync echoes, local writes,
    /// etc.) — we just need to refetch when `currentRoundId` itself changes.
    /// Without this cache, `currentRound` did a fresh `FetchDescriptor` +
    /// `context.fetch` on every access; ActiveRoundView's body reads
    /// currentRound 10+ times per evaluation, which produced ~30-40
    /// SwiftData fetches per second during play, backed up the main thread,
    /// and caused watchOS to throttle Digital Crown event delivery.
    private var _cachedCurrentRound: Round?
    private var _cachedCurrentRoundIdForRound: UUID?

    var currentRound: Round? {
        guard let id = currentRoundId, let context = context else {
            _cachedCurrentRound = nil
            _cachedCurrentRoundIdForRound = nil
            return nil
        }
        if id == _cachedCurrentRoundIdForRound, let cached = _cachedCurrentRound {
            return cached
        }
        let descriptor = FetchDescriptor<Round>(predicate: #Predicate { $0.id == id })
        let fetched = (try? context.fetch(descriptor))?.first
        _cachedCurrentRound = fetched
        _cachedCurrentRoundIdForRound = id
        return fetched
    }

    var currentHole: Hole? { currentRound?.currentHole }

    var hasPreviousHole: Bool { currentRound.map { $0.hole(before: $0.currentHoleNumber) != nil } ?? false }
    var hasNextHole: Bool { currentRound.map { $0.hole(after: $0.currentHoleNumber) != nil } ?? false }

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

    /// Re-pull the cached clubs/types/sets arrays from SwiftData. Call
    /// after any local mutation that could change them (hydrate, insert,
    /// delete, set switch).
    func refreshClubsCache() {
        guard let context = context else { return }
        let fetchedClubsRaw = (try? context.fetch(FetchDescriptor<ClubData>())) ?? []
        // Canonical bag order (Drive → Putt) so the crown has a stable,
        // predictable progression. SwiftData fetches have no inherent
        // ordering and return rows in insertion order; without sorting, the
        // crown was jumbled. This used to sort by averageDistance descending,
        // which broke for user-created types (no distance → sorted to the
        // bottom) and reshuffled the bag whenever a distance was edited.
        let fetchedTypes = ((try? context.fetch(FetchDescriptor<ClubTypeData>())) ?? []).inBagOrder()
        let fetchedSets  = (try? context.fetch(FetchDescriptor<ClubSet>())) ?? []
        // Order clubs by their type's averageDistance so iterating
        // availableClubs (e.g. for any UI that doesn't go through
        // activeSetClubs) also gets the right order.
        let typeRank: [UUID: Int] = Dictionary(uniqueKeysWithValues: fetchedTypes.enumerated().map { ($1.id, $0) })
        let fetchedClubs = fetchedClubsRaw.sorted {
            (typeRank[$0.clubTypeId] ?? Int.max) < (typeRank[$1.clubTypeId] ?? Int.max)
        }
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

    /// Clubs of the active ClubSet, in type order. This is what the
    /// watch crown should scroll through during a round — NOT the full
    /// `availableClubs` catalog (which can have multiple clubs per type
    /// when the user owns alternates). Falls back to `availableClubs` when
    /// no active set exists yet (shouldn't happen post-seed, but safe).
    // MARK: - Connectivity Setup

    private func setupConnectivity() {
        connectivity.onReceiveHoleDetectionData = { [weak self] detectionData in
            ClientEventLogger.log("blob.received", detail: [
                "courseId": .string(detectionData.courseId.uuidString),
                "blobCount": .integer(detectionData.blobs.count)
            ])
            DispatchQueue.main.async {
                self?.applyBlobDetectionResults(detectionData, courseId: detectionData.courseId)
            }
        }
        connectivity.onReceiveHoleDetectionStatus = { [weak self] courseId, state in
            self?.handlePhoneBlobStatus(courseId: courseId, state: state)
        }
        // Round rows the phone forwards from the server: the watch's copy of a
        // solo round follows the phone's changes as they happen.
        connectivity.onReceiveRoundRow = { table, kind, record in
            Task { @MainActor in
                RealtimeSync.shared.applyRelayed(table: table, kind: kind, recordJSON: record)
            }
        }
        // Phone is the authority for filter settings now (dev menu lives
        // in iOS Settings → Developer → Green Filters). Watch only RECEIVES
        // — its setupConnectivity assigns to holeFilterSettings on inbound,
        // didSet persists to UserDefaults. No outbound push from watch.
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

    // MARK: - Helpers

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
}

extension WatchDataStore: RoundStoreShared {
    func endRoundForLifecycle(_ round: Round, reason: String) {
        endRound(reason: reason)
    }

    func adoptServerActivity(_ date: Date, for round: Round) {
        round.lastActivityAt = date
        try? context?.save()
    }

    func refreshAfterReconcile() {
        refreshCurrentRound()
    }

    var requestsLocationOnRoundStart: Bool { false }
}
