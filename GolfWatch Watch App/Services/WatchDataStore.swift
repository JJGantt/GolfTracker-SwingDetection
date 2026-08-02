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

    private func hydrateBlobDetectionForCourse(_ courseId: UUID) {
        Task { [weak self] in
            guard let self = self else { return }
            if let cached = await self.fetchServerCachedBlobs(courseId: courseId) {
                await MainActor.run {
                    self.applyBlobDetectionResults(cached, courseId: courseId)
                    ClientEventLogger.log("blob.serverCache.hit", detail: [
                        "courseId": .string(courseId.uuidString),
                        "blobCount": .integer(cached.blobs.count),
                        "device": .string("watch"),
                        "trigger": .string("resumeRound")
                    ])
                }
            } else {
                ClientEventLogger.log("blob.serverCache.miss", detail: [
                    "courseId": .string(courseId.uuidString),
                    "device": .string("watch"),
                    "trigger": .string("resumeRound")
                ])
            }
        }
    }

    /// Store arrived blob results and unstick the placement UI. Single
    /// funnel for every delivery path (up-front cache hit, pending-window
    /// poll, WC receive, resume hydrate) so they all also re-assert the
    /// round's `holeDetectionEnabled` flag.
    func applyBlobDetectionResults(_ data: CourseHoleDetectionData, courseId: UUID) {
        holeDetectionDataByCourse[courseId] = data
        pendingBlobDetectionCourseIds.remove(courseId)
        ensureHoleDetectionEnabled(forCourse: courseId)
    }

    /// Re-assert `holeDetectionEnabled` on the current round when blob data
    /// is applied for its course. The flag is flipped on at blob-request
    /// time, but a cross-device round upsert can clobber it back to false —
    /// the iPhone's reconcile races the watch's flip (seen live at Wolf
    /// Hollow 2026-07-05: the round row carried false 36s after the watch
    /// wrote true). The picker gate (AddHoleNavigationView) returns zero
    /// candidates while the flag is off, so without this heal, blobs arrive
    /// and stay invisible. Re-writing at data-apply time converges every
    /// clobber source: our upsert carries true and realtime propagates it
    /// back to the other device.
    func ensureHoleDetectionEnabled(forCourse courseId: UUID) {
        guard let round = currentRound,
              round.courseId == courseId,
              round.holeDetectionEnabled != true else { return }
        round.holeDetectionEnabled = true
        try? context?.save()
        SupabaseSync.shared.upsertRound(round)
        ClientEventLogger.log("blob.holeDetectionEnabled.healed", detail: [
            "roundId": .string(round.id.uuidString)
        ])
        objectWillChange.send()
    }

    /// Fire-and-forget fetch of `courses.osm_polygons` for the given course
    /// id; on success, populates `osmCourseDataByCourse[courseId]`.
    /// Resolved canonical green per hole_number for a course. Cached at
    /// round-start so addNextHole can read without re-querying. Resolution:
    ///   1. THIS user has a pick → use it
    ///   2. ≥3 distinct users picked AND ≥75% share the same blob_id →
    ///      that blob's centroid + modal par
    ///   3. Else nil (placement view will appear)
    /// Manual picks (blob_id == NULL) never participate in voting but
    /// satisfy rule 1 for the picker themselves.
    private(set) var canonicalHolePlacementsByCourse: [UUID: [Int: (lat: Double, lon: Double, par: Int?)]] = [:]

    private struct PickRow: Decodable {
        let user_id: UUID
        let hole_number: Int
        let blob_id: UUID?
        let latitude: Double?
        let longitude: Double?
        let par: Int?
    }

    private func fetchCanonicalHolePlacements(courseId: UUID) async -> [Int: (lat: Double, lon: Double, par: Int?)] {
        let myUserId = WatchAuthSession.shared.currentUserId.flatMap(UUID.init(uuidString:))
        let blobs = await fetchServerCachedBlobs(courseId: courseId)
        let blobsById: [UUID: HoleDetectionBlob] = Dictionary(uniqueKeysWithValues: (blobs?.blobs ?? []).map { ($0.id, $0) })
        let picks: [PickRow]
        do {
            picks = try await SupabaseManager.shared
                .from("course_hole_picks")
                .select("user_id,hole_number,blob_id,latitude,longitude,par")
                .eq("course_id", value: courseId.uuidString)
                .execute()
                .value
        } catch {
            ClientEventLogger.log("canonicalPlacements.fetchError", detail: [
                "courseId": .string(courseId.uuidString),
                "error": .string("\(error)")
            ])
            return [:]
        }
        let byHole = Dictionary(grouping: picks, by: { $0.hole_number })
        var result: [Int: (lat: Double, lon: Double, par: Int?)] = [:]
        for (hole, rows) in byHole {
            // Rule 1: this user has a pick
            if let mine = rows.first(where: { $0.user_id == myUserId }) {
                if let bid = mine.blob_id, let blob = blobsById[bid] {
                    let c = blob.centroidCoordinate
                    result[hole] = (c.latitude, c.longitude, mine.par)
                } else if let lat = mine.latitude, let lon = mine.longitude {
                    result[hole] = (lat, lon, mine.par)
                }
                continue
            }
            // Rule 2: voting on blob_id (manual picks excluded)
            let blobPicks = rows.compactMap { $0.blob_id }
            let distinctVoters = Set(rows.compactMap { $0.blob_id != nil ? $0.user_id : nil }).count
            guard distinctVoters >= 3 else { continue }
            let counts = Dictionary(grouping: blobPicks, by: { $0 }).mapValues { $0.count }
            guard let (modalBlob, modalCount) = counts.max(by: { $0.value < $1.value }) else { continue }
            let share = Double(modalCount) / Double(distinctVoters)
            guard share >= 0.75 else { continue }
            guard let blob = blobsById[modalBlob] else { continue }
            // Modal par among the agreeing voters
            let agreeingPars = rows.filter { $0.blob_id == modalBlob }.compactMap { $0.par }
            let parCounts = Dictionary(grouping: agreeingPars, by: { $0 }).mapValues { $0.count }
            let modalPar = parCounts.max(by: { $0.value < $1.value })?.key
            let c = blob.centroidCoordinate
            result[hole] = (c.latitude, c.longitude, modalPar)
        }
        ClientEventLogger.log("canonicalPlacements.fetched", detail: [
            "courseId": .string(courseId.uuidString),
            "holeCount": .integer(result.count),
            "pickRowCount": .integer(picks.count)
        ])
        return result
    }

    /// Direct PostgREST read of `courses.blob_detection_results`. Mirrors
    /// the iPhone's `DataStore.fetchBlobDetectionResults`. Watch reads the
    /// cache itself rather than asking the iPhone over WC, so blob overlays
    /// work even when the iPhone is asleep / out of range.
    private func fetchServerCachedBlobs(courseId: UUID) async -> CourseHoleDetectionData? {
        struct Row: Decodable { let blob_detection_results: CourseHoleDetectionData? }
        do {
            let rows: [Row] = try await SupabaseManager.shared
                .from("courses")
                .select("blob_detection_results")
                .eq("id", value: courseId.uuidString)
                .limit(1)
                .execute()
                .value
            return rows.first?.blob_detection_results
        } catch {
            ClientEventLogger.log("blob.serverCache.fetchError", detail: [
                "courseId": .string(courseId.uuidString),
                "error": .string("\(error)")
            ])
            return nil
        }
    }

    /// Called from `refreshCurrentRound` whenever a round becomes current
    /// without having gone through the resolver this session.
    private func hydrateOsmDataForCourse(_ courseId: UUID) {
        struct Row: Decodable { let osm_polygons: OSMCourseData? }
        ClientEventLogger.log("greenHydrate.start", detail: [
            "courseId": .string(courseId.uuidString)
        ])
        Task { [weak self] in
            do {
                let rows: [Row] = try await SupabaseManager.shared
                    .from("courses")
                    .select("osm_polygons")
                    .eq("id", value: courseId.uuidString)
                    .limit(1)
                    .execute()
                    .value
                let osm = rows.first?.osm_polygons
                ClientEventLogger.log("greenHydrate.fetched", detail: [
                    "rowCount": .integer(rows.count),
                    "hasOsm": .bool(osm != nil),
                    "greenCount": .integer(osm?.greens.count ?? 0),
                    "holeCount": .integer(osm?.holes.count ?? 0)
                ])
                guard let osm = osm else { return }
                await MainActor.run {
                    self?.osmCourseDataByCourse[courseId] = osm
                }
            } catch {
                ClientEventLogger.log("greenHydrate.failed", detail: [
                    "error": .string("\(error)")
                ])
            }
        }
    }

    @Published var holeDetectionDataByCourse: [UUID: CourseHoleDetectionData] = [:]
    /// Course ids whose blob detection request has been sent to the iPhone
    /// but not yet returned. Drives the placement-view "Analyzing course
    /// geometry…" waiting state. Cleared when blob data arrives or after
    /// a 60s timeout.
    @Published var pendingBlobDetectionCourseIds: Set<UUID> = []
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
    private var pendingCoursePickerCompletion: ((RoundResolver.CourseCandidate?) -> Void)?

    /// Set after the resolver runs the GCAPI search — the user picks one of
    /// the ranked candidates OR "Course not listed" (which completes with nil
    /// → round starts without scorecard data, manual par + GPS yardage).
    @Published var pendingScorecardPicker: PendingScorecardPicker?
    fileprivate var pendingScorecardPickerCompletion: ((GCAPICourse?) -> Void)?

    /// Name-this-course prompt. Set when the resolver hits the `.manual`
    /// path — nothing identified where the user is, so they name it and the
    /// course is stored at their GPS for next time. A name is REQUIRED;
    /// completing with nil cancels the round rather than falling back to a
    /// throwaway placeholder course.
    @Published var pendingCourseNamePrompt: Bool = false
    private var pendingCourseNameCompletion: ((String?) -> Void)?


    struct PendingScorecardPicker {
        let originalName: String
        let candidates: [RoundResolver.ScorecardCandidate]
    }

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

    private var lifecycleTimer: Timer?

    private init() {
        loadUserDefaults()
        setupConnectivity()
        // Touch the auto-advance monitor so its location subscription wires up
        // immediately at app launch.
        _ = AutoAdvanceMonitor.shared
        startRoundLifecycleSweep()
    }

    /// 60s timer evaluating the current round against the inactivity (>1h)
    /// and off-course (>2km) gates. Fires `endRound` on a positive result.
    /// Idempotent — keeps running even when no current round exists, since
    /// the next round picks up at the next tick.
    private func startRoundLifecycleSweep() {
        lifecycleTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.evaluateRoundLifecycle()
        }
        RunLoop.main.add(timer, forMode: .common)
        lifecycleTimer = timer
        // Fire once at startup so a stale round on launch ends immediately
        // without waiting 60s.
        evaluateRoundLifecycle()
    }

    private func evaluateRoundLifecycle() {
        guard let round = currentRound else { return }
        // Test mode: pass nil location so the off-course sweep is skipped.
        // The simulated GPS pin won't be near the round's actual hole
        // coordinates, which would otherwise auto-end every test round
        // within a minute. Inactivity (>1h wall clock) still applies.
        let location = LocationManager.shared.isTestModeEnabled
            ? nil
            : LocationManager.shared.location?.coordinate
        let decision = RoundLifecycleEvaluator.evaluate(
            round: round,
            location: location
        )
        guard decision.shouldEnd else { return }
        if RoundLifecycleEvaluator.isInactivityReason(decision.reason) {
            // Local lastActivityAt may be stale (user scoring on the phone
            // while the watch sat idle — solo rounds have no Realtime on
            // watch) — verify against the server before ending. Offline →
            // trust local, as before.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let fresh = await RoundLifecycleEvaluator.serverLastActivityAt(roundId: round.id),
                   Date().timeIntervalSince(fresh) <= RoundLifecycleEvaluator.inactivityThreshold {
                    round.lastActivityAt = fresh
                    try? self.context?.save()
                    return
                }
                self.endRound(reason: decision.reason ?? "lifecycle")
            }
        } else {
            endRound(reason: decision.reason ?? "lifecycle")
        }
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
                // ClubSet.typeSelections lives in a separate join table on
                // Supabase (one row per type per set). We fetch it here so
                // we can populate the local ClubSet's typeSelections array
                // — without this the watch sees an empty active set and
                // the crown filters to zero clubs.
                async let selectionsAsync: [ClubSetTypeSelectionDTO] = supabase.from("club_set_type_selections").select().execute().value
                let (types, clubs, sets, selections) = try await (typesAsync, clubsAsync, setsAsync, selectionsAsync)
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
                    // Group selections by club_set_id so we can attach them
                    // to each set as we upsert it.
                    let selectionsBySetId = Dictionary(grouping: selections, by: { $0.club_set_id })
                    for s in sets {
                        Self.upsertClubSet(s, selections: selectionsBySetId[s.id] ?? [], into: context)
                    }

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
            existing.sortOrder = t.sort_order
        } else {
            context.insert(ClubTypeData(id: id, name: t.name, isDefault: t.is_default ?? false, averageDistance: t.average_distance, sortOrder: t.sort_order))
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

    private static func upsertClubSet(_ s: ClubSetDTO, selections: [ClubSetTypeSelectionDTO], into context: ModelContext) {
        let id = s.id
        let descriptor = FetchDescriptor<ClubSet>(predicate: #Predicate { $0.id == id })
        let dc = s.date_created.flatMap(Self.parseISO) ?? Date()
        let dm = s.date_modified.flatMap(Self.parseISO) ?? Date()
        let typeSelections = selections.map { TypeSelection(typeId: $0.type_id, activeClubId: $0.active_club_id) }
        if let existing = (try? context.fetch(descriptor))?.first {
            existing.name = s.name
            existing.isActive = s.is_active ?? false
            existing.dateCreated = dc
            existing.dateModified = dm
            existing.typeSelections = typeSelections
        } else {
            context.insert(ClubSet(id: id, name: s.name, typeSelections: typeSelections, isActive: s.is_active ?? false, dateCreated: dc, dateModified: dm))
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
        // Safety net: if the active set has no typeSelections (e.g. join
        // table fetch failed, or hydrate happened before the selections
        // were available), fall back to the full catalog rather than
        // showing zero clubs in the crown.
        if activeSet.typeSelections.isEmpty {
            return availableClubs
        }
        // Order: follow the type order from clubTypes (Drive → Putt) rather
        // than typeSelections' internal order, so the crown has a stable,
        // predictable progression.
        let typeOrder = clubTypes.map(\.id)
        let selectionsByType = Dictionary(uniqueKeysWithValues:
            activeSet.typeSelections.map { ($0.typeId, $0.activeClubId) }
        )
        let mapped = typeOrder.compactMap { typeId -> ClubData? in
            guard let activeClubId = selectionsByType[typeId] ?? nil else { return nil }
            return availableClubs.first { $0.id == activeClubId }
        }
        // Same safety net at the result level — prevents a sparse / broken
        // selection from silently emptying the crown.
        return mapped.isEmpty ? availableClubs : mapped
    }

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

    // MARK: - Stroke Management

    @discardableResult
    func addStroke(clubId: UUID, trajectoryHeading: Double? = nil, coordinate: CLLocationCoordinate2D? = nil, isPenalty: Bool = false) -> UUID? {
        guard let round = currentRound, let context = context else { return nil }
        guard let strokeCoordinate = coordinate ?? LocationManager.shared.location?.coordinate else { return nil }

        // Tee shot is away — the distance heuristic can take over until the
        // approach brings us back inside gpsModerateYards. No-op after the
        // first stroke on the hole.
        LocationManager.shared.releaseTeeHoldIfNeeded()

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
            trajectoryHeading: trajectoryHeading,
            relAltMeters: LocationManager.shared.currentRelativeAltitudeMeters
        )
        context.insert(stroke)
        round.strokes.append(stroke)
        round.lastActivityAt = Date()
        try? context.save()

        // Push to Supabase via the shared sync layer.
        SupabaseSync.shared.upsertStroke(stroke, roundId: round.id)
        SupabaseSync.shared.upsertRound(round)
        objectWillChange.send()
        return stroke.id
    }

    /// Convenience: adds a penalty stroke at the current GPS. Penalties no
    /// longer get placed on the map (the placement-mode UI was removed); each
    /// call is just "+1 to the score." Picks any available club for the
    /// `clubId` slot since `Stroke.clubId` is non-optional and the value is
    /// unused for penalties.
    @discardableResult
    func addPenaltyStroke() -> UUID? {
        guard let club = availableClubs.first else { return nil }
        return addStroke(clubId: club.id, isPenalty: true)
    }

    /// Penalty stroke count for a hole. Drives the orange "P: N" readout.
    func penaltyCount(for hole: Hole) -> Int {
        currentRound?.strokes.filter { $0.holeNumber == hole.number && $0.isPenalty }.count ?? 0
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
        round.lastActivityAt = Date()
        try? context.save()
        SupabaseSync.shared.upsertRound(round)
        ClientEventLogger.logBattery(hole: newIndex + 1)
        objectWillChange.send()
    }

    /// Mark the current round finished. Manual button + lifecycle sweep both
    /// route through here. Idempotent — re-ending an already-ended round
    /// is a no-op.
    func endRound(reason: String = "manual") {
        guard let round = currentRound, let context = context else { return }
        guard round.endedAt == nil else { return }
        round.endedAt = Date()
        try? context.save()
        SupabaseSync.shared.upsertRound(round)
        // Drain the upload queue in the background so the UI doesn't
        // block on the final flush. The queue is disk-persistent, so a
        // fire-and-forget Task is safe — incomplete drain just means
        // the next round picks up the leftovers. After the drain, fold
        // this round's altitude rows into the shared height map.
        let foldInCourseId = round.courseId
        let foldInRoundId = round.id
        let skipFoldIn = round.locationTestModeEnabled == true
        Task { @MainActor in
            ElevationReadout.shared.stop()
            HoleHeightCellCache.shared.clear()
            HistoricalFirstStrokeCache.shared.clear()
        }
        Task {
            await LocationManager.shared.stopPathRecording()
            if !skipFoldIn {
                await ElevationFoldIn.run(courseId: foldInCourseId,
                                          roundId: foldInRoundId)
            }
        }
        dprint("⌚ [WatchDataStore] Ended round \(round.id) — \(reason)")
        refreshCurrentRound()
        objectWillChange.send()
    }

    /// End every still-open round. Used by startRound — once the user
    /// kicks off a new round, any prior open round is implicitly over.
    func endAnyOngoingRound(reason: String) {
        guard let context = context else { return }
        let descriptor = FetchDescriptor<Round>(
            predicate: #Predicate { $0.endedAt == nil }
        )
        let open = (try? context.fetch(descriptor)) ?? []
        let now = Date()
        for r in open {
            r.endedAt = now
            SupabaseSync.shared.upsertRound(r)
            // This path previously skipped the elevation fold-in entirely —
            // rounds auto-ended by a new round start never reached the
            // height map. Route them through the durable fold-in.
            let courseId = r.courseId
            let roundId = r.id
            if r.locationTestModeEnabled != true {
                Task { await ElevationFoldIn.run(courseId: courseId, roundId: roundId) }
            }
        }
        if !open.isEmpty {
            try? context.save()
            dprint("⌚ [WatchDataStore] Ended \(open.count) prior round(s) — \(reason)")
        }
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
            ClientEventLogger.log("blob.received", detail: [
                "courseId": .string(detectionData.courseId.uuidString),
                "blobCount": .integer(detectionData.blobs.count)
            ])
            DispatchQueue.main.async {
                self?.applyBlobDetectionResults(detectionData, courseId: detectionData.courseId)
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
        // If canonical resolution covers this hole_number (this user's
        // own pick or cross-user voting threshold), pre-populate so
        // HolePlacementView is skipped.
        let canonical = canonicalHolePlacementsByCourse[round.courseId]?[nextHoleNumber]
        let newHole: Hole
        if let pick = canonical {
            let coord = CLLocationCoordinate2D(latitude: pick.lat, longitude: pick.lon)
            newHole = Hole(number: nextHoleNumber, coordinate: coord, par: pick.par, teeId: round.selectedTeeId)
            ClientEventLogger.log("addNextHole.canonicalHydrated", detail: [
                "holeNumber": .integer(nextHoleNumber),
                "lat": .double(pick.lat),
                "lon": .double(pick.lon)
            ])
        } else {
            newHole = Hole(number: nextHoleNumber)
        }
        context.insert(newHole)
        round.holes.append(newHole)
        round.currentHoleIndex = nextHoleNumber - 1
        try? context.save()
        ClientEventLogger.log("addNextHole.saved", detail: ["holeNumber": .integer(nextHoleNumber), "holeCount": .integer(round.holes.count)])
        SupabaseSync.shared.upsertRound(round)
        ClientEventLogger.log("addNextHole.upsertEnqueued")
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
    }

    // MARK: - Start Round (resolver-backed)

    func startRoundAtCurrentLocation() {
        // Catch up with the server before creating anything. performStartRound
        // auto-ends any prior in-progress round, so starting here while a
        // phone-started round exists but hasn't synced yet produces TWO live
        // rounds — both upsert, and `currentRound` on each device picks the
        // most recent by date, so the two can disagree about which round is
        // being played. One round at a time, reachable from either device.
        Task { @MainActor in
            await RealtimeSync.shared.reconcileRoundsWithSupabase()
            refreshCurrentRound()
            guard currentRound == nil else {
                // Say so. Aborting silently makes Start Round look broken —
                // the user taps it, nothing happens, and there's no hint that
                // a round they can't see is the reason.
                ClientEventLogger.log("round.start.abortedExistingRound")
                roundStartStatus = "Round already in progress"
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    if self?.roundStartStatus == "Round already in progress" {
                        self?.roundStartStatus = nil
                    }
                }
                return
            }
            beginRoundResolution()
        }
    }

    /// How long to wait for a GPS fix before giving up and asking the user to
    /// name the place themselves.
    private static let roundStartLocationWaitSeconds: TimeInterval = 12

    private func beginRoundResolution() {
        guard let loc = LocationManager.shared.location?.coordinate else {
            // No fix YET is not no fix. Dropping straight to the manual path
            // here means prompting for a course name, which reads as "which
            // course are you at?" — the user types the right name and gets a
            // brand-new course with no OSM data, no holes and no centroid, so
            // no blob detection and manual green placement, while the real
            // course sits in the table unused.
            roundStartStatus = "Waiting for GPS…"
            Task { @MainActor in
                let deadline = Date().addingTimeInterval(Self.roundStartLocationWaitSeconds)
                while Date() < deadline {
                    if LocationManager.shared.location != nil { break }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
                guard let c = LocationManager.shared.location?.coordinate else {
                    ClientEventLogger.log("round.start.noGPSAfterWait")
                    roundStartStatus = nil
                    startManualQuickRound()
                    return
                }
                resolveRound(at: c)
            }
            return
        }
        resolveRound(at: loc)
    }

    private func resolveRound(at coordinate: CLLocationCoordinate2D) {
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
                    self?.pendingCoursePicker = candidates
                    self?.pendingCoursePickerCompletion = choose
                }
            },
            scorecardPicker: { [weak self] originalName, ranked, choose in
                DispatchQueue.main.async {
                    self?.pendingScorecardPicker = PendingScorecardPicker(
                        originalName: originalName,
                        candidates: ranked
                    )
                    self?.pendingScorecardPickerCompletion = choose
                }
            },
            courseNamePrompt: { [weak self] complete in
                DispatchQueue.main.async {
                    self?.pendingCourseNameCompletion = complete
                    self?.pendingCourseNamePrompt = true
                }
            },
            completion: { [weak self] resolution in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.roundStartStatus = nil
                    if let resolution = resolution {
                        self.handleResolved(resolution)
                    }
                    // A nil resolution means the user backed out — cancelled
                    // the course picker, or cancelled the name prompt on the
                    // manual path. Start nothing. This used to fall back to
                    // startManualQuickRound, which now prompts for a name and
                    // would re-open the prompt the user just dismissed.
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
        ClientEventLogger.log("pickTee.enter", detail: [
            "teeId": .string(tee?.id.uuidString ?? "nil"),
            "hasResolution": .bool(pendingTeePickerResolution != nil)
        ])
        let resolution = pendingTeePickerResolution
        pendingTeePicker = nil
        pendingTeePickerResolution = nil
        guard let resolution = resolution else { return }
        startRound(from: resolution, selectedTeeId: tee?.id)
        ClientEventLogger.log("pickTee.afterStartRound")
    }

    func pickCourseCandidate(_ candidate: RoundResolver.CourseCandidate?) {
        let cb = pendingCoursePickerCompletion
        pendingCoursePicker = nil
        pendingCoursePickerCompletion = nil
        cb?(candidate)
    }

    /// User picked a scorecard candidate from the picker (or "Course not
    /// listed" → nil → round starts without a scorecard).
    func pickScorecardCandidate(_ course: GCAPICourse?) {
        let cb = pendingScorecardPickerCompletion
        pendingScorecardPicker = nil
        pendingScorecardPickerCompletion = nil
        cb?(course)
    }

    private func startRound(from resolution: RoundResolver.Resolution, selectedTeeId: UUID?) {
        // Tier-3 / OSM-greens-empty paths benefit from canonical-pick
        // hydration so users skip placement view for holes they've already
        // played OR for holes ≥3 users have agreed on. Pre-fetch off the
        // main thread, then create the round with coords pre-populated.
        // Tier-1 (full OSM) skips — never enters placement view.
        let needsHydration: Bool = {
            if resolution.tier == .full, let osm = resolution.osmData, !osm.greens.isEmpty {
                return false
            }
            return true
        }()
        if !needsHydration {
            performStartRound(from: resolution, selectedTeeId: selectedTeeId, canonicalPicks: [:])
            return
        }
        let courseId = resolution.courseId
        Task { [weak self] in
            guard let self = self else { return }
            let picks = await self.fetchCanonicalHolePlacements(courseId: courseId)
            await MainActor.run {
                self.canonicalHolePlacementsByCourse[courseId] = picks
                self.performStartRound(from: resolution, selectedTeeId: selectedTeeId, canonicalPicks: picks)
            }
        }
    }

    private func performStartRound(from resolution: RoundResolver.Resolution,
                                   selectedTeeId: UUID?,
                                   canonicalPicks: [Int: (lat: Double, lon: Double, par: Int?)]) {
        ClientEventLogger.log("perform.start.enter", detail: [
            "courseId": .string(resolution.courseId.uuidString),
            "tier": .string("\(resolution.tier)"),
            "selectedTeeId": selectedTeeId.map { .string($0.uuidString) } ?? .null,
            "canonicalPickCount": .integer(canonicalPicks.count)
        ])
        guard let context = context else {
            ClientEventLogger.log("perform.start.bail.noContext")
            return
        }
        // Starting a new round implies any prior open round is finished.
        endAnyOngoingRound(reason: "new round starting")
        ClientEventLogger.log("perform.start.afterEndPrior")
        if let osm = resolution.osmData {
            osmCourseDataByCourse[resolution.courseId] = osm
        }

        // Round.holes is a snapshot — built from OSM data when available,
        // otherwise a single placeholder hole the user fills in as they go.
        // For the placeholder path, consult canonicalPicks so we skip
        // HolePlacementView for hole 1 if it's resolved.
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
        } else if let pick = canonicalPicks[1] {
            let coord = CLLocationCoordinate2D(latitude: pick.lat, longitude: pick.lon)
            holes = [Hole(number: 1, coordinate: coord, par: pick.par, teeId: selectedTeeId)]
        } else {
            holes = [Hole(number: 1, teeId: selectedTeeId)]
        }

        // Ensure a local Course mirror of the (shared) row exists. The
        // resolver already INSERTed the shared row when isExistingCourse=false,
        // and the row already exists when true. We mirror so view code can
        // resolve names/holes against SwiftData without round-tripping.
        let lookupId = resolution.courseId
        let courseDescriptor = FetchDescriptor<Course>(
            predicate: #Predicate { $0.id == lookupId }
        )
        let existingCourse = (try? context.fetch(courseDescriptor))?.first
        let course: Course
        if let existing = existingCourse {
            existing.name = resolution.courseName
            if let ext = resolution.scorecardCourse.map({ String($0.id) }) {
                existing.externalCourseId = ext
            }
            course = existing
        } else {
            course = Course(
                id: resolution.courseId,
                name: resolution.courseName,
                holes: [],
                centerLat: resolution.courseCoordinate.latitude,
                centerLon: resolution.courseCoordinate.longitude,
                externalCourseId: resolution.scorecardCourse.map { String($0.id) }
            )
            context.insert(course)
        }

        ClientEventLogger.log("perform.start.afterCourseMirror", detail: [
            "holeCount": .integer(holes.count)
        ])
        let newRound = Round(
            courseId: resolution.courseId,
            courseName: resolution.courseName,
            holes: holes,
            selectedTeeId: selectedTeeId
        )
        for h in holes { context.insert(h) }
        context.insert(newRound)
        try? context.save()
        ClientEventLogger.log("perform.start.afterContextSave", detail: [
            "roundId": .string(newRound.id.uuidString)
        ])
        refreshCurrentRound()
        ClientEventLogger.log("perform.start.afterRefreshCurrentRound")
        // Only mirror our local Course edits to Supabase when the row was
        // already there (isExistingCourse=true). When isExistingCourse=false
        // AND the resolver had OSM data, the resolver itself INSERTed the
        // canonical shared row carrying all the geo + osm_polygons fields —
        // calling upsertCourse here would overwrite that with the thinner
        // local mirror.
        //
        // Exception: manual ("Course not listed") and MapKit-fallback paths
        // both have isExistingCourse=false AND osmData=nil — the resolver
        // skipped the INSERT for them. iPhone-side blob detection needs a
        // shared `courses` row to exist (it does fetchAndInsertCourse by
        // id) so we upsert a thin row here for those paths.
        if resolution.isExistingCourse {
            SupabaseSync.shared.upsertCourse(course)
        } else if resolution.osmData == nil {
            SupabaseSync.shared.upsertCourse(course)
        }
        SupabaseSync.shared.upsertRound(newRound)
        ClientEventLogger.log("perform.start.afterUpsertRound")
        dprint("⌚ [WatchDataStore] Started round at \(resolution.courseName) (tier=\(resolution.tier), \(holes.count) holes, tee=\(selectedTeeId?.uuidString ?? "none"), existing=\(resolution.isExistingCourse))")

        // Path + altitude capture. Hole-number provider re-reads the live
        // round each sample so every row is tagged with the hole the user
        // is actually on at capture time, not at upload.
        if let uid = WatchAuthSession.shared.currentUserId {
            ClientEventLogger.log("perform.start.beforeStartPathRecording")
            let roundId = newRound.id
            LocationManager.shared.startPathRecording(roundId: roundId, userId: uid) { [weak self] in
                guard let self, let r = self.currentRound, r.id == roundId else { return 1 }
                let sorted = r.holes.sorted { $0.number < $1.number }
                let idx = max(0, min(r.currentHoleIndex, sorted.count - 1))
                return sorted.indices.contains(idx) ? sorted[idx].number : 1
            }
            ClientEventLogger.log("perform.start.afterStartPathRecording")
        } else {
            ClientEventLogger.log("altitude.recording.skipped.noUid", detail: [
                "roundId": .string(newRound.id.uuidString)
            ])
        }

        // Live elevation-to-green readout. Pre-load cells for this
        // course's holes so the readout has data to consume on the very
        // first path-sample tick.
        let elevationCourseId = newRound.courseId
        let elevationHoleNumbers = newRound.holes.map { $0.number }
        Task { @MainActor in
            await HoleHeightCellCache.shared.loadForCourse(
                courseId: elevationCourseId, holeNumbers: elevationHoleNumbers
            )
            ElevationReadout.shared.start(courseId: elevationCourseId)
            await HistoricalFirstStrokeCache.shared.loadForCourse(
                courseId: elevationCourseId
            )
        }

        // Hydrate per-hole yardage AND par for the selected tee. Yardage
        // drives the scorecard yardage readout on each new hole; par
        // drives the auto-skip of the par picker in HolePlacementView.
        // Wiped on round end / start of next round.
        teeHoleYardages = [:]
        teeHolePars = [:]
        if let teeId = selectedTeeId {
            Task { [weak self] in
                do {
                    let holes = try await GolfCourseAPIService.shared.cachedHoles(forTeeId: teeId)
                    let yardageMap = Dictionary(uniqueKeysWithValues: holes.compactMap { h -> (Int, Int)? in
                        guard let yds = h.yardage else { return nil }
                        return (h.holeNumber, yds)
                    })
                    let parMap = Dictionary(uniqueKeysWithValues: holes.compactMap { h -> (Int, Int)? in
                        guard let par = h.par else { return nil }
                        return (h.holeNumber, par)
                    })
                    await MainActor.run {
                        self?.teeHoleYardages = yardageMap
                        self?.teeHolePars = parMap
                    }
                } catch {
                    dprint("⌚ [WatchDataStore] cached tee holes fetch failed: \(error)")
                }
            }
        }
        // Blob detection is the fallback for courses without usable OSM
        // green data. Two cases that need it:
        //   1. No OSM data at all (course outside OSM, or relation
        //      missing entirely).
        //   2. OSM data was returned, but the relation is incomplete —
        //      no `golf=green` features tagged inside the course bounds.
        //      Wekiva GC is an example: relation + bunkers + cartpaths
        //      are mapped but not greens/tees/holes. Without falling
        //      back here, the user lands in manual placement mode with
        //      nothing on the map to work with.
        // Blob detection is needed unless OSM gave us a complete picture:
        // tier == .full (hole refs exactly 1..N) AND every hole has its
        // green polygon. Partial OSM (e.g. Sweetwater: 3 holes, 2 greens
        // for an 18-hole course) used to short-circuit blob detection
        // because `osm.greens.isEmpty` was false — but the 2 greens cover
        // 2 holes, leaving 16 with nothing. Always pull blobs as a
        // supplement when OSM isn't clean-full.
        let needsBlobDetection: Bool = {
            guard let osm = resolution.osmData else { return true }
            if osm.tier != .full { return true }
            return osm.greens.count < osm.holes.count
        }()
        if needsBlobDetection {
            let reason: String = resolution.osmData == nil
                ? "noOsmData"
                : "osmGreensEmpty"
            ClientEventLogger.log("blob.request", detail: [
                "courseId": .string(resolution.courseId.uuidString),
                "reason": .string(reason)
            ])
            // Flip the round's hole-detection flag on so the placement UI
            // (HolePlacementView) actually shows blob candidates as overlays.
            // Without this, blobs arrive at the watch but the picker filters
            // them out — round.holeDetectionEnabled defaults to false.
            if let round = currentRound, round.holeDetectionEnabled != true {
                round.holeDetectionEnabled = true
                try? context.save()
                SupabaseSync.shared.upsertRound(round)
                ClientEventLogger.log("blob.request.holeDetectionEnabled", detail: [
                    "roundId": .string(round.id.uuidString)
                ])
                objectWillChange.send()
            }
            // Mark pending so HolePlacementView shows the waiting overlay
            // and disables manual placement until results arrive (or
            // timeout). Cleared on direct-fetch hit OR via
            // `connectivity.onReceiveHoleDetectionData` for the WC fallback.
            pendingBlobDetectionCourseIds.insert(resolution.courseId)
            let courseId = resolution.courseId
            // Server-cache direct fetch. The iPhone WC round-trip is only
            // needed when no cached results exist and the analyzer has to
            // run — analyzer is iPhone-only. If the cache hits, apply it
            // here and skip WC entirely. On miss, fall back to the WC
            // request so the iPhone runs the analyzer.
            Task { @MainActor in
                if let cached = await self.fetchServerCachedBlobs(courseId: courseId) {
                    self.applyBlobDetectionResults(cached, courseId: courseId)
                    ClientEventLogger.log("blob.serverCache.hit", detail: [
                        "courseId": .string(courseId.uuidString),
                        "blobCount": .integer(cached.blobs.count),
                        "device": .string("watch")
                    ])
                    return
                }
                ClientEventLogger.log("blob.serverCache.miss", detail: [
                    "courseId": .string(courseId.uuidString),
                    "device": .string("watch")
                ])
                WatchConnectivityManager.shared.sendHoleDetectionRequest(courseId: courseId)
                // Keep polling the server cache while pending. The iPhone
                // analyzer typically finishes and uploads in ~20s, but its
                // WC delivery is a file transfer above 50KB — opportunistic,
                // can take minutes. A single up-front cache check loses that
                // race (Wolf Hollow 2026-07-05: upload landed 22s after the
                // check; the picker opened empty and never looked again).
                for _ in 0..<5 {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    guard self.pendingBlobDetectionCourseIds.contains(courseId),
                          self.holeDetectionDataByCourse[courseId] == nil else { return }
                    if let cached = await self.fetchServerCachedBlobs(courseId: courseId) {
                        self.applyBlobDetectionResults(cached, courseId: courseId)
                        ClientEventLogger.log("blob.serverCache.hit", detail: [
                            "courseId": .string(courseId.uuidString),
                            "blobCount": .integer(cached.blobs.count),
                            "device": .string("watch"),
                            "trigger": .string("pendingPoll")
                        ])
                        return
                    }
                }
            }
            // 60s safety timeout — if blobs never come back (iPhone offline,
            // analyzer error), unstick the UI so user can manually place.
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let self = self else { return }
                if self.pendingBlobDetectionCourseIds.contains(courseId)
                    && self.holeDetectionDataByCourse[courseId] == nil {
                    self.pendingBlobDetectionCourseIds.remove(courseId)
                    ClientEventLogger.log("blob.request.timedOut", detail: [
                        "courseId": .string(courseId.uuidString)
                    ])
                }
            }
        }
    }

    /// Answer the name-this-course prompt. Nil or blank cancels the round.
    func submitCourseName(_ name: String?) {
        let cb = pendingCourseNameCompletion
        pendingCourseNamePrompt = false
        pendingCourseNameCompletion = nil
        cb?(name)
    }

    /// Start a round with no GPS fix at all. The user still names the course,
    /// but with no coordinate there's nothing to anchor it to, so it can't be
    /// matched by proximity next time — it'll be re-named on the next visit.
    ///
    /// This used to create `Round(courseId: UUID(), courseName: "Quick Start")`
    /// with NO Course row anywhere, which is why those rounds ended up
    /// orphaned in Supabase pointing at a course id that never existed.
    func startManualQuickRound() {
        pendingCourseNameCompletion = { [weak self] entered in
            guard let self = self, let context = self.context else { return }
            let name = (entered ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }   // cancelled — no round

            let course = Course(name: name)
            context.insert(course)
            let firstHole = Hole(number: 1)
            let newRound = Round(courseId: course.id, courseName: name, holes: [firstHole])
            context.insert(firstHole)
            context.insert(newRound)
            try? context.save()
            self.refreshCurrentRound()
            SupabaseSync.shared.upsertCourse(course)
            SupabaseSync.shared.upsertRound(newRound)
        }
        pendingCourseNamePrompt = true
    }

    func startQuickRound() { startRoundAtCurrentLocation() }

    private static func statusString(for step: RoundResolver.Step) -> String? {
        switch step {
        case .locating: return "Locating…"
        case .searchingShared: return "Checking nearby courses…"
        case .searchingPOIs: return "Searching nearby courses…"
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
            out.append(contentsOf: holeFilterSettings.apply(to: detectionData.blobs))
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

    /// Putts taken on this hole — strokes whose club resolves to type
    /// name "Putt". Same definition `AutoAdvanceMonitor` uses for its
    /// putt-since-arrival gate, kept consistent so the UI count and the
    /// auto-advance trigger never disagree.
    func puttCount(for hole: Hole) -> Int {
        guard let strokes = currentRound?.strokes else { return 0 }
        return strokes.reduce(0) { count, stroke in
            guard stroke.holeNumber == hole.number else { return count }
            guard let club = availableClubs.first(where: { $0.id == stroke.clubId }) else { return count }
            return getTypeName(for: club) == "Putt" ? count + 1 : count
        }
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

    /// Club types skipped by distance-based prediction unconditionally.
    /// - "Sand": special-purpose, only chosen by manual override.
    /// "Putt" is NOT here — it's excluded conditionally by the caller (only
    /// when an OSM green polygon is available for the current hole, since
    /// polygon containment is the authoritative signal in that case). When
    /// no polygon exists, distance-based prediction can still pick putter
    /// as the fallback.
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

    /// `deltaMeters` — elevation delta to the target from ElevationReadout.
    /// When present, each candidate is scored against the plays-like
    /// distance computed with that club's own landing angle (self-
    /// consistent, no dependence on the currently selected club) instead
    /// of the raw yardage. Nil (no elevation solution) falls back to the
    /// raw-distance match.
    func predictClubIndex(forDistance yards: Int, deltaMeters: Double? = nil, clubs: [ClubData], clubTypes: [ClubTypeData], mode: ClubPredictionMode, customAverages: [String: Int] = [:], disabledClubs: Set<String> = []) -> Int? {
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
        let closest = PlaysLike.bestCandidate(
            distanceYards: yards,
            deltaMeters: deltaMeters,
            candidates: clubDistances.map { (item: $0, typeName: $0.name, averageYards: $0.average) }
        )
        return closest?.index
    }
}

// (ClubTypeDTO / ClubDTO / ClubSetDTO moved to Models.swift so both iOS
// and watch targets share the same wire shape.)
