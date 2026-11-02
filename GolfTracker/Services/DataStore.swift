import Foundation
import CoreLocation
import MapKit
import SwiftData
import UIKit

@MainActor
class DataStore: ObservableObject {
    /// Shared instance — mirrors `WatchDataStore.shared`. Singletons that need
    /// access to the iOS data layer (like `MultiplayerView`) read from this
    /// rather than relying on environment injection.
    static let shared = DataStore()

    @Published var courses: [Course] = []
    @Published var rounds: [Round] = []
    @Published var clubTypes: [ClubTypeData] = []
    @Published var availableClubs: [ClubData] = []
    @Published var clubSets: [ClubSet] = []
    @Published var errorMessage: String?
    @Published var holeDetectionDataByCourse: [UUID: CourseHoleDetectionData] = [:]
    @Published var holeDetectionRunStateByCourse: [UUID: HoleDetectionRunState] = [:]
    @Published var holeFilterSettings: HoleDetectionFilterSettings = .default
    @Published var playerStats: PlayerStats = .empty

    /// The round currently being played on iOS — set by `HolePlayView.onAppear`,
    /// cleared by its `onDisappear`. Used by `MultiplayerView` to know which
    /// round to host into. Mirrors `WatchDataStore.currentRoundId`'s purpose.
    @Published var currentRoundId: UUID?

    /// Maximum window for a round to count as "in progress" — beyond this,
    /// the round is treated as abandoned and stops appearing as current.
    /// 8 hours covers slow rounds + lunch breaks; anything beyond is
    /// effectively a forgotten round.
    static let currentRoundMaxAgeSeconds: TimeInterval = 8 * 60 * 60

    // MARK: - GPS Round Start state


    struct PendingTeePicker: Identifiable {
        var id = UUID()
        let courseName: String
        let tees: [CachedCourseTee]
    }

    @Published var roundStartStatus: String?
    @Published var pendingCoursePicker: [RoundResolver.CourseCandidate]?
    var pendingCoursePickerCompletion: ((RoundResolver.CourseCandidate?) -> Void)?
    @Published var pendingScorecardPicker: PendingScorecardPicker?
    var pendingScorecardPickerCompletion: ((GCAPICourse?) -> Void)?

    /// Name-this-course prompt. Set when the resolver hits the `.manual`
    /// path — nothing identified where the user is, so they name it and the
    /// course is stored at their GPS for next time. A name is REQUIRED;
    /// completing with nil cancels the round rather than falling back to a
    /// throwaway placeholder course.
    @Published var pendingCourseNamePrompt: Bool = false
    var pendingCourseNameCompletion: ((String?) -> Void)?

    @Published var pendingTeePicker: PendingTeePicker?
    private var pendingTeePickerResolution: RoundResolver.Resolution?

    /// The user's currently-in-progress round, derived from the data — most
    /// recent Round started within `currentRoundMaxAgeSeconds`. Cross-device
    /// by design: rounds inserted by the watch arrive here via Realtime
    /// sync, so the phone's "Continue Round" picks them up automatically.
    /// Returns nil if no recent round exists.
    var currentRound: Round? {
        let cutoff = Date().addingTimeInterval(-Self.currentRoundMaxAgeSeconds)
        return rounds
            .filter { $0.endedAt == nil && $0.date >= cutoff }
            .max(by: { $0.date < $1.date })
    }

    /// Set at app startup via `configure(container:)`.
    private(set) var modelContainer: ModelContainer?
    /// Single shared `ModelContext` — see WatchDataStore for the rationale.
    /// Per-access fresh contexts hit cross-context cache-coherence issues
    /// where saves aren't immediately visible to subsequent fetches.
    private var sharedContext: ModelContext?
    private var context: ModelContext? { sharedContext }
    /// Public read-only accessor so `RealtimeSync` can apply postgres-changes
    /// echoes into the SAME context our local mutations use.
    var modelContext: ModelContext? { sharedContext }

    private let holeDetectionFileName = "holeDetectionData.json"
    private let playerStatsFileName = "playerStats.json"
    private let holeFilterSettingsKey = "holeFilterSettings"
    private let holeDetectionAnalyzer = HoleDetectionAnalyzer()
    private let holeDetectionTestCenter = CLLocationCoordinate2D(
        latitude: 30.285357365597697,
        longitude: -81.74623642434663
    )

    init() {
        dprint("🏌️ DataStore initialized!")
        // SwiftData fetches happen inside configure(container:) below — at init
        // time the container isn't attached yet, so the @Published arrays start
        // empty and get filled after configure runs.
        loadHoleDetectionData()
        loadHoleFilterSettings()
        dprint("🏌️ DataStore loaded \(courses.count) courses, \(rounds.count) rounds, \(clubTypes.count) club types, \(availableClubs.count) clubs, and \(clubSets.count) club sets")

        // Initialize with default club types if needed
        if clubTypes.isEmpty {
            clubTypes = ClubTypeData.defaultClubTypes()
            saveClubTypes()
            dprint("🏌️ Initialized with \(clubTypes.count) default club types")
        }

        // Initialize with default clubs if needed
        if availableClubs.isEmpty {
            // Create default clubs using the club type IDs
            for clubType in clubTypes {
                let club = ClubData(name: "Default", clubTypeId: clubType.id, isDefault: true)
                availableClubs.append(club)
            }
            saveClubs()
            dprint("🏌️ Initialized with \(availableClubs.count) default clubs")
        }

        // Create default club set if no sets exist
        if clubSets.isEmpty && !clubTypes.isEmpty {
            // Create type selections with default clubs
            let typeSelections = clubTypes.map { clubType -> TypeSelection in
                let defaultClub = availableClubs.first(where: { $0.clubTypeId == clubType.id })
                return TypeSelection(typeId: clubType.id, activeClubId: defaultClub?.id)
            }
            let defaultSet = ClubSet(
                name: "Default Set",
                typeSelections: typeSelections,
                isActive: true
            )
            clubSets.append(defaultSet)
            saveClubSets()
        }

        // Load or build aggregate stats
        loadPlayerStats()
        if playerStats.totalRounds != rounds.count {
            // Stale cache — rebuild from current rounds
            rebuildPlayerStats()
        }

        // Set up Watch Connectivity callbacks
        setupWatchConnectivity()
        startRoundLifecycleSweep()
    }

    var lifecycleTimer: Timer?

    private func setupWatchConnectivity() {
        // Round/Stroke sync moved to DB (Realtime + SwiftData). WC only retains
        // hole detection data + hole filter settings paths now.
        // Phone is authority for filter settings — push current value to
        // watch on every WC session activation so the watch picks up the
        // latest after a launch / reconnect. The phone's GreenFiltersView
        // also pushes on each individual change for live updates.
        WatchConnectivityManager.shared.onSessionActivated = { [weak self] in
            guard let self = self else { return }
            WatchConnectivityManager.shared.sendHoleFilterSettings(self.holeFilterSettings)
        }

        // Watch-driven blob detection request. Watch hits this whenever it
        // starts/resumes a round on a course; iPhone runs the analyzer (or
        // returns cached data) and ships results back via the existing
        // sendHoleDetectionData flow. Lets the watch always have blob data
        // for visual comparison against OSM polygons, even when the iOS
        // user never explicitly opted into hole detection.
        WatchConnectivityManager.shared.onReceiveHoleDetectionRequest = { [weak self] courseId in
            guard let self = self else { return }
            Task { @MainActor in
                // Try cache → SwiftData → Supabase fetch-by-id. The third
                // step is the new one: when the round was resolved on the
                // watch (shared courses table), the iPhone may not have
                // received the Realtime INSERT echo yet, so the local
                // SwiftData has no matching row. We fetch directly from
                // Supabase and insert it before kicking off blob detection.
                var course: Course? = self.courses.first(where: { $0.id == courseId })
                if course == nil, let context = self.context {
                    let descriptor = FetchDescriptor<Course>(predicate: #Predicate { $0.id == courseId })
                    course = (try? context.fetch(descriptor))?.first
                }
                if course == nil {
                    course = await self.fetchAndInsertCourse(by: courseId)
                }
                ClientEventLogger.log("blob.request.received", detail: [
                    "courseId": .string(courseId.uuidString),
                    "courseFound": .bool(course != nil),
                    "courseName": course.map { .string($0.name) } ?? .null
                ])
                guard course != nil else {
                    WatchConnectivityManager.shared.sendHoleDetectionStatus(courseId: courseId, state: .failed)
                    return
                }
                self.enqueueWatchHoleDetection(courseId)
            }
        }

        // Clubs/types now sync via DB — both devices read from SwiftData and
        // observe Realtime changes; no WC push needed at startup.
    }

    /// Public entry point so watch-initiated hole detection requests can
    /// kick off the same pipeline. Cached results return immediately;
    /// otherwise the analyzer runs and ships results back via WC when done.
    /// Direct Supabase fetch for a course by id, with local SwiftData
    /// insert. Used when the watch refers to a shared-courses row that the
    /// iPhone hasn't received via Realtime yet. Returns the freshly-inserted
    /// Course on success, nil if the row doesn't exist or the fetch fails.
    @MainActor
    private func fetchAndInsertCourse(by courseId: UUID) async -> Course? {
        guard let context = self.context else { return nil }
        struct Row: Decodable {
            let id: UUID
            let name: String
            let center_lat: Double?
            let center_lon: Double?
            let osm_id: Int64?
            let external_course_id: String?
            // Decoded loosely — the OSM polygon shape is JSONB; we only
            // need the basic course fields here for blob detection.
        }
        do {
            let rows: [Row] = try await SupabaseManager.shared
                .from("courses")
                .select("id,name,center_lat,center_lon,osm_id,external_course_id")
                .eq("id", value: courseId.uuidString)
                .limit(1)
                .execute()
                .value
            guard let row = rows.first else {
                ClientEventLogger.log("blob.request.fetchCourse.missing", detail: [
                    "courseId": .string(courseId.uuidString)
                ])
                return nil
            }
            let course = Course(
                id: row.id,
                name: row.name,
                centerLat: row.center_lat,
                centerLon: row.center_lon,
                osmId: row.osm_id,
                externalCourseId: row.external_course_id
            )
            // The course's hole rows too, under their server ids. A course
            // brought in without them gets holes built locally with new ids,
            // and the server's then arrive as a second set.
            struct HoleRow: Decodable {
                let id: UUID
                let number: Int
                let latitude: Double?
                let longitude: Double?
                let par: Int?
                let owner_id: UUID?
            }
            let fetched: [HoleRow] = try await SupabaseManager.shared
                .from("holes")
                .select("id,number,latitude,longitude,par,owner_id")
                .eq("course_id", value: courseId.uuidString)
                .execute()
                .value
            // One per number; the user's own hole beats the shared one.
            let holeRows = Dictionary(grouping: fetched, by: \.number).values.compactMap { rows in
                rows.first { $0.owner_id != nil } ?? rows.first
            }
            course.holes = holeRows.map { r in
                let id = r.id
                let hole = (try? context.fetch(FetchDescriptor<Hole>(predicate: #Predicate { $0.id == id })))?.first
                    ?? Hole(id: r.id, number: r.number)
                hole.number = r.number
                hole.latitude = r.latitude
                hole.longitude = r.longitude
                hole.par = r.par
                hole.ownerId = r.owner_id
                return hole
            }
            context.insert(course)
            try? context.save()
            ClientEventLogger.log("blob.request.fetchCourse.inserted", detail: [
                "courseId": .string(courseId.uuidString),
                "name": .string(row.name)
            ])
            // Refresh the cached `courses` array
            loadCourses()
            return course
        } catch {
            ClientEventLogger.log("blob.request.fetchCourse.error", detail: [
                "courseId": .string(courseId.uuidString),
                "error": .string("\(error)")
            ])
            return nil
        }
    }

    /// Server-side blob-detection cache fetch. Returns nil on miss /
    /// network error / decode error so the caller falls back to the
    /// analyzer.
    @MainActor
    private func fetchBlobDetectionResults(courseId: UUID) async -> CourseHoleDetectionData? {
        struct Row: Decodable {
            let blob_detection_results: CourseHoleDetectionData?
        }
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

    /// Server-side blob-detection cache write. Fire-and-forget; failures
    /// are non-fatal — the in-memory + JSON cache still works.
    private func uploadBlobDetectionResults(courseId: UUID, data: CourseHoleDetectionData) {
        struct UpdateRow: Encodable {
            let blob_detection_results: CourseHoleDetectionData
            let blob_detection_at: String
        }
        let row = UpdateRow(
            blob_detection_results: data,
            blob_detection_at: ISO8601DateFormatter().string(from: Date())
        )
        Task { @MainActor in
            do {
                try await SupabaseManager.shared
                    .from("courses")
                    .update(row)
                    .eq("id", value: courseId.uuidString)
                    .execute()
                ClientEventLogger.log("blob.serverCache.uploaded", detail: [
                    "courseId": .string(courseId.uuidString),
                    "blobCount": .integer(data.blobs.count)
                ])
            } catch {
                ClientEventLogger.log("blob.serverCache.uploadError", detail: [
                    "courseId": .string(courseId.uuidString),
                    "error": .string("\(error)")
                ])
            }
            // `done` tells the watch to read the server cache, so it goes out
            // only once the write has landed (or failed — the WC data push
            // still carries the blobs then).
            self.finishHoleDetection(courseId: courseId, state: .done)
        }
    }

    func runHoleDetection(for course: Course) {
        startHoleDetection(for: course, allowCache: true, persistResult: true)
    }

    // MARK: - Watch-requested analysis queue

    private let watchHoleDetectionQueueKey = "watchHoleDetectionQueue"

    /// Courses the watch asked to analyze that have not finished yet.
    ///
    /// A watch request usually arrives with this app in the background —
    /// WatchConnectivity launches it there to deliver the message — and the
    /// analyzer's MapKit snapshots do not complete for a backgrounded app. On
    /// 2026-09-07 the Blue Sky request started that way, died without logging
    /// anything, and the course never got blobs. So a request only ever runs
    /// while the app is on screen; otherwise it waits here and the watch is
    /// told `queued`. Persisted, so a request survives the app being killed.
    private var watchHoleDetectionQueue: [UUID] {
        get {
            (UserDefaults.standard.stringArray(forKey: watchHoleDetectionQueueKey) ?? [])
                .compactMap(UUID.init(uuidString:))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.uuidString), forKey: watchHoleDetectionQueueKey)
        }
    }

    /// Covers a run the user backgrounds midway, so it can finish.
    private var holeDetectionBackgroundTasks: [UUID: UIBackgroundTaskIdentifier] = [:]

    private func enqueueWatchHoleDetection(_ courseId: UUID) {
        if !watchHoleDetectionQueue.contains(courseId) {
            watchHoleDetectionQueue.append(courseId)
        }
        drainWatchHoleDetectionQueue()
    }

    /// Run every queued watch request, if the app is on screen. Called when a
    /// request arrives and on every foreground.
    func drainWatchHoleDetectionQueue() {
        let queue = watchHoleDetectionQueue
        guard !queue.isEmpty, let context = context else { return }
        let appState = UIApplication.shared.applicationState
        guard appState == .active else {
            for courseId in queue {
                WatchConnectivityManager.shared.sendHoleDetectionStatus(courseId: courseId, state: .queued)
            }
            ClientEventLogger.log("blob.request.queued", detail: [
                "courseIds": .string(queue.map(\.uuidString).joined(separator: ",")),
                "appState": .string(appState == .background ? "background" : "inactive")
            ])
            return
        }
        for courseId in queue {
            let course = courses.first(where: { $0.id == courseId })
                ?? (try? context.fetch(FetchDescriptor<Course>(predicate: #Predicate { $0.id == courseId })))?.first
            guard let course else {
                ClientEventLogger.log("blob.analyzer.courseMissing", detail: [
                    "courseId": .string(courseId.uuidString)
                ])
                finishHoleDetection(courseId: courseId, state: .failed)
                continue
            }
            startHoleDetection(for: course, allowCache: true, persistResult: true)
        }
    }

    /// The single exit of every analysis run: tell the watch where it ended,
    /// drop the course from the queue, release the background task.
    private func finishHoleDetection(courseId: UUID, state: HoleDetectionPhoneState) {
        watchHoleDetectionQueue.removeAll { $0 == courseId }
        WatchConnectivityManager.shared.sendHoleDetectionStatus(courseId: courseId, state: state)
        if let task = holeDetectionBackgroundTasks.removeValue(forKey: courseId) {
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    /// Domain, code and message — enough to tell a MapKit throttle from a
    /// render failure from a timeout in `client_events`.
    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain)#\(ns.code): \(ns.localizedDescription)"
    }

    private var holeDetectionFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(holeDetectionFileName)
    }

    private var playerStatsFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(playerStatsFileName)
    }
    
    func loadCourses() {
        guard let context = context else { return }
        courses = (try? context.fetch(FetchDescriptor<Course>())) ?? []
    }

    func loadRounds() {
        guard let context = context else { return }
        rounds = (try? context.fetch(FetchDescriptor<Round>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
    }

    /// Persist locally only — mutation sites own their targeted Supabase
    /// upserts (see saveRounds).
    func saveCourses() {
        guard let context = context else { return }
        // SwiftData tracks changes on @Model objects — just commit. Any
        // unattached new courses get inserted first.
        for course in courses where course.modelContext == nil {
            context.insert(course)
        }
        try? context.save()
    }

    /// Persist locally only. Supabase mirroring is the responsibility of
    /// each mutation site (targeted upserts) — this used to re-upsert every
    /// round, stroke, and target on every call, which fanned out into
    /// hundreds of HTTP requests per recorded stroke.
    func saveRounds() {
        guard let context = context else { return }
        for round in rounds where round.modelContext == nil {
            context.insert(round)
        }
        try? context.save()
    }

    /// Called by GolfTrackerApp at startup to wire SwiftData persistence.
    /// The signed-in user, as the owner of the course holes they place.
    private var currentUserUUID: UUID? {
        AuthManager.shared.currentUserId.flatMap(UUID.init(uuidString:))
    }

    func configure(container: ModelContainer) {
        self.modelContainer = container
        let context = ModelContext(container)
        self.sharedContext = context
        // Before anything can start a round: split rounds off the course
        // holes they may still share, then bring the server's rows in line.
        SupabaseSync.shared.markRoundHolesForRewrite(context.separateRoundHolesFromCourseHoles())
        context.backfillCurrentHoleNumbers()
        Task { @MainActor in
            await SupabaseSync.shared.rewritePendingRoundHoles(context: context)
            await RealtimeSync.shared.reconcileCourseHoles()
        }
        loadCourses()
        loadRounds()
        loadClubTypes()
        loadClubs()
        loadClubSets()

        // Reconcile clubs/types/sets with Supabase asynchronously. Was
        // previously a sync "if local empty, seed defaults" check, but
        // that re-created defaults with fresh UUIDs every time SwiftData
        // looked empty (reinstall, container reset, etc.) — pushing
        // duplicates to Supabase. Now we check Supabase first: if it has
        // clubs, hydrate locally; if it's also empty, seed cleanly once.
        Task { await reconcileClubsWithSupabase() }

        loadPlayerStats()
        if playerStats.totalRounds != rounds.count {
            rebuildPlayerStats()
        }
    }

    /// Async reconciliation between local SwiftData and Supabase for the
    /// clubs/types/sets catalog. Runs once at startup. Three branches:
    ///   1. Local already populated → nothing to do.
    ///   2. Local empty + Supabase populated → hydrate from Supabase.
    ///   3. Local empty + Supabase empty → seed fresh defaults locally and
    ///      push to Supabase. This is the only path that creates new rows.
    private func reconcileClubsWithSupabase() async {
        // Already have a local catalog — assume it's authoritative.
        let hasLocalCatalog = !clubTypes.isEmpty && !availableClubs.isEmpty && !clubSets.isEmpty
        if hasLocalCatalog { return }
        // Not signed in — defer (sign-in handler can re-trigger via
        // configure, or we can revisit if the auth flow needs an explicit
        // hook here).
        guard AuthManager.shared.currentUserId != nil else { return }
        let supabase = SupabaseManager.shared
        do {
            async let typesAsync: [ClubTypeDTO] = supabase.from("club_types").select().execute().value
            async let clubsAsync: [ClubDTO] = supabase.from("clubs").select().execute().value
            async let setsAsync: [ClubSetDTO] = supabase.from("club_sets").select().execute().value
            // Selections live in a join table (not a column on club_sets).
            // Fetch them so the rebuilt local ClubSet has its full
            // typeSelections array — otherwise the watch's active-set
            // filter resolves to an empty crown.
            async let selectionsAsync: [ClubSetTypeSelectionDTO] = supabase.from("club_set_type_selections").select().execute().value
            let (remoteTypes, remoteClubs, remoteSets, remoteSelections) = try await (typesAsync, clubsAsync, setsAsync, selectionsAsync)

            if !remoteTypes.isEmpty || !remoteClubs.isEmpty || !remoteSets.isEmpty {
                // Branch 2: Supabase has data → hydrate locally.
                await MainActor.run {
                    hydrateClubsFromRemote(types: remoteTypes, clubs: remoteClubs, sets: remoteSets, selections: remoteSelections)
                }
            } else {
                // Branch 3: Both empty → seed fresh defaults once.
                await MainActor.run {
                    seedDefaultCatalog()
                }
            }
        } catch {
            dprint("📱 [DataStore] club reconcile failed: \(error.localizedDescription)")
        }
    }

    /// Insert remote DTOs into local SwiftData. Idempotent — upserts by id.
    private func hydrateClubsFromRemote(types: [ClubTypeDTO], clubs: [ClubDTO], sets: [ClubSetDTO], selections: [ClubSetTypeSelectionDTO]) {
        guard let context = context else { return }
        for t in types {
            let id = t.id
            let descriptor = FetchDescriptor<ClubTypeData>(predicate: #Predicate { $0.id == id })
            if (try? context.fetch(descriptor))?.first == nil {
                context.insert(ClubTypeData(id: id, name: t.name, isDefault: t.is_default ?? false, averageDistance: t.average_distance, sortOrder: t.sort_order))
            }
        }
        for c in clubs {
            let id = c.id
            let descriptor = FetchDescriptor<ClubData>(predicate: #Predicate { $0.id == id })
            if (try? context.fetch(descriptor))?.first == nil {
                context.insert(ClubData(id: id, name: c.name, clubTypeId: c.club_type_id, isDefault: c.is_default ?? false))
            }
        }
        let selectionsBySetId = Dictionary(grouping: selections, by: { $0.club_set_id })
        for s in sets {
            let id = s.id
            let descriptor = FetchDescriptor<ClubSet>(predicate: #Predicate { $0.id == id })
            let typeSels = (selectionsBySetId[id] ?? []).map {
                TypeSelection(typeId: $0.type_id, activeClubId: $0.active_club_id)
            }
            if let existing = (try? context.fetch(descriptor))?.first {
                existing.typeSelections = typeSels
            } else {
                let dc = s.date_created.flatMap(Self.parseISODate) ?? Date()
                let dm = s.date_modified.flatMap(Self.parseISODate) ?? Date()
                context.insert(ClubSet(id: id, name: s.name, typeSelections: typeSels, isActive: s.is_active ?? false, dateCreated: dc, dateModified: dm))
            }
        }
        try? context.save()
        loadClubTypes()
        loadClubs()
        loadClubSets()
        objectWillChange.send()
    }

    /// One-time seed of the default 16 club types + a single default ClubData
    /// per type + one ClubSet that uses them as the active selection. Only
    /// runs when both local SwiftData AND Supabase are empty for the user.
    private func seedDefaultCatalog() {
        clubTypes = ClubTypeData.defaultClubTypes()
        saveClubTypes()
        for clubType in clubTypes {
            let club = ClubData(name: "Default", clubTypeId: clubType.id, isDefault: true)
            availableClubs.append(club)
        }
        saveClubs()
        let typeSelections = clubTypes.map { clubType -> TypeSelection in
            let defaultClub = availableClubs.first(where: { $0.clubTypeId == clubType.id })
            return TypeSelection(typeId: clubType.id, activeClubId: defaultClub?.id)
        }
        let defaultSet = ClubSet(name: "Default Set", typeSelections: typeSelections, isActive: true)
        clubSets.append(defaultSet)
        saveClubSets()
        objectWillChange.send()
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static func parseISODate(_ s: String) -> Date? {
        if let d = isoFormatter.date(from: s) { return d }
        let alt = ISO8601DateFormatter()
        alt.formatOptions = [.withInternetDateTime]
        return alt.date(from: s)
    }

    // MARK: - Player Stats

    func loadPlayerStats() {
        guard FileManager.default.fileExists(atPath: playerStatsFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: playerStatsFileURL)
            playerStats = try JSONDecoder().decode(PlayerStats.self, from: data)
        } catch {
            dprint("⚠️ Failed to load player stats: \(error.localizedDescription)")
        }
    }

    private func savePlayerStats() {
        do {
            let data = try JSONEncoder().encode(playerStats)
            try data.write(to: playerStatsFileURL)
        } catch {
            dprint("⚠️ Failed to save player stats: \(error.localizedDescription)")
        }
    }

    /// Recomputes aggregate stats from all rounds and persists the result.
    /// Called after a round ends or is deleted. Also safe to call manually.
    func rebuildPlayerStats() {
        playerStats = StatsEngine.compute(
            rounds: rounds,
            courses: courses,
            clubs: availableClubs,
            clubTypes: clubTypes
        )
        savePlayerStats()
        dprint("📊 Player stats rebuilt: \(rounds.count) rounds, \(playerStats.perClubTypeStats.count) club types")
    }

    func loadClubTypes() {
        guard let context = context else { return }
        // Bag order at the load site, so every consumer (Stats, club-set
        // editor, prediction, watch crown) inherits one order for free.
        clubTypes = ((try? context.fetch(FetchDescriptor<ClubTypeData>())) ?? []).inBagOrder()
        // Backfill: types that predate `sortOrder` (or arrived from a device
        // that never set it) land in canonical position above, then get
        // stamped so the order is authoritative from here on. One-time —
        // `renumberBagOrder` reports no change once everything is numbered.
        if clubTypes.renumberBagOrder() {
            try? context.save()
            for t in clubTypes { SupabaseSync.shared.upsertClubType(t) }
        }
    }

    func saveClubTypes() {
        guard let context = context else { return }
        for t in clubTypes where t.modelContext == nil { context.insert(t) }
        try? context.save()
        for t in clubTypes { SupabaseSync.shared.upsertClubType(t) }
    }

    func loadClubs() {
        guard let context = context else { return }
        availableClubs = (try? context.fetch(FetchDescriptor<ClubData>())) ?? []
    }

    func loadClubSets() {
        guard let context = context else { return }
        clubSets = (try? context.fetch(FetchDescriptor<ClubSet>())) ?? []
    }

    func saveClubs() {
        guard let context = context else { return }
        for c in availableClubs where c.modelContext == nil { context.insert(c) }
        try? context.save()
        for c in availableClubs { SupabaseSync.shared.upsertClub(c) }
    }

    func saveClubSets() {
        guard let context = context else { return }
        for s in clubSets where s.modelContext == nil { context.insert(s) }
        try? context.save()
        for s in clubSets { SupabaseSync.shared.upsertClubSet(s) }
    }

    func loadHoleDetectionData() {
        guard FileManager.default.fileExists(atPath: holeDetectionFileURL.path) else { return }

        do {
            let data = try Data(contentsOf: holeDetectionFileURL)
            let detections = try JSONDecoder().decode([CourseHoleDetectionData].self, from: data)
            holeDetectionDataByCourse = Dictionary(uniqueKeysWithValues: detections.map { ($0.courseId, $0) })
        } catch {
            dprint("📱 [DataStore] Failed to load hole detection data: \(error.localizedDescription)")
        }
    }

    func saveHoleDetectionData() {
        do {
            let detections = Array(holeDetectionDataByCourse.values)
            let data = try JSONEncoder().encode(detections)
            try data.write(to: holeDetectionFileURL)
        } catch {
            dprint("📱 [DataStore] Failed to save hole detection data: \(error.localizedDescription)")
        }
    }

    func loadHoleFilterSettings() {
        guard let data = UserDefaults.standard.data(forKey: holeFilterSettingsKey),
              let settings = try? JSONDecoder().decode(HoleDetectionFilterSettings.self, from: data) else {
            holeFilterSettings = .default
            return
        }
        holeFilterSettings = settings
    }

    func saveHoleFilterSettings() {
        guard let data = try? JSONEncoder().encode(holeFilterSettings) else { return }
        UserDefaults.standard.set(data, forKey: holeFilterSettingsKey)
    }

    func holeDetectionStatus(for courseId: UUID) -> HoleDetectionRunState? {
        holeDetectionRunStateByCourse[courseId]
    }

    func filteredHoleDetectionBlobs(for courseId: UUID) -> [HoleDetectionBlob] {
        guard let data = holeDetectionDataByCourse[courseId] else { return [] }
        return holeFilterSettings.apply(to: data.blobs)
    }

    /// Decoded OSM data for a course, sourced from `Course.osmPolygons`
    /// (already populated by `RoundResolver` / `OSMCourseService`). The
    /// watch keeps a separate `[UUID: OSMCourseData]` dict; on iOS we
    /// just decode on demand from the SwiftData column. Returns nil if
    /// the course has no OSM coverage or the payload fails to decode.
    func osmCourseData(forCourseId id: UUID) -> OSMCourseData? {
        guard let course = courses.first(where: { $0.id == id }),
              let raw = course.osmPolygons else { return nil }
        return try? JSONDecoder().decode(OSMCourseData.self, from: raw)
    }

    func addCourse(name: String) {
        let course = Course(name: name, holes: [])
        courses.append(course)
        saveCourses()
        SupabaseSync.shared.upsertCourse(course)
    }

    func deleteCourse(_ course: Course) {
        courses.removeAll { $0.id == course.id }
        saveCourses()
        SupabaseSync.shared.deleteCourse(id: course.id)
    }

    func updateCourseInfo(_ course: Course, name: String, rating: Double?, slope: Int?) {
        guard let index = courses.firstIndex(where: { $0.id == course.id }) else { return }
        courses[index].name = name
        courses[index].rating = rating
        courses[index].slope = slope
        saveCourses()
        SupabaseSync.shared.upsertCourse(courses[index])
    }

    func updateCourseCity(_ course: Course) {
        guard courses.firstIndex(where: { $0.id == course.id }) != nil,
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
                    SupabaseSync.shared.upsertCourse(self.courses[currentIndex])
                }
            }
        }
    }

    func addHole(to course: Course, coordinate: CLLocationCoordinate2D, par: Int? = nil, userLocation: CLLocationCoordinate2D? = nil) {
        guard let index = courses.firstIndex(where: { $0.id == course.id }) else { return }
        let holeNumber = courses[index].holes.count + 1
        let hole = Hole(number: holeNumber, coordinate: coordinate, par: par)
        hole.ownerId = currentUserUUID
        courses[index].holes.append(hole)
        saveCourses()
        SupabaseSync.shared.upsertMyCourseHole(hole, courseId: course.id)

        dprint("📱 [DataStore] Added hole #\(holeNumber) to course \(course.name)")

        // Update city if this is the first hole or if city is not set
        if courses[index].city == nil {
            updateCourseCity(courses[index])
        }

        // Update active round with new hole data and resync to Watch
        updateActiveRoundHoles(for: course)
    }

    /// Carries course hole edits into the round in progress at that course,
    /// matched by hole number. The round has its own `Hole`s, never the
    /// course's, so this copies values and adds or removes the round's holes
    /// to match. Finished rounds keep the holes they were played with.
    private func updateActiveRoundHoles(for course: Course) {
        guard let round = rounds.filter({ $0.courseId == course.id && $0.endedAt == nil })
                .max(by: { $0.date < $1.date }),
              let courseHoles = courses.first(where: { $0.id == course.id })?.holes.oneByNumber else { return }

        var unmatched = Dictionary(round.holes.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        var added: [Int] = []
        for courseHole in courseHoles {
            if let roundHole = unmatched.removeValue(forKey: courseHole.number) {
                roundHole.latitude = courseHole.latitude
                roundHole.longitude = courseHole.longitude
                roundHole.par = courseHole.par
            } else {
                round.holes.append(courseHole.roundCopy(roundId: round.id, teeId: round.selectedTeeId))
                added.append(courseHole.number)
            }
        }
        for extra in unmatched.values {
            round.holes.removeAll { $0.id == extra.id }
            context?.delete(extra)
            SupabaseSync.shared.deleteRoundHole(id: extra.id)
        }

        // If a new hole was added, point the round at it
        if let newest = added.max() {
            round.currentHoleNumber = newest
        }
        saveRounds()
        SupabaseSync.shared.upsertRound(round)
        SupabaseSync.shared.upsertRoundHoles(round)
    }

    /// Deleting and renumbering rewrite every hole's number, so they apply to
    /// a course of the user's own holes only (`canRenumberHoles`): a shared
    /// hole's number is OSM's, and no client changes it.
    func canRenumberHoles(in course: Course) -> Bool {
        !course.holes.contains { $0.isShared }
    }

    func deleteHole(_ hole: Hole, from course: Course) {
        guard let courseIndex = courses.firstIndex(where: { $0.id == course.id }),
              canRenumberHoles(in: courses[courseIndex]) else { return }
        let lastNumber = courses[courseIndex].holes.map(\.number).max() ?? hole.number
        courses[courseIndex].holes.removeAll { $0.id == hole.id }
        // Renumber remaining holes. SwiftData relationship arrays are
        // unordered — sort by current number before reassigning.
        let remaining = courses[courseIndex].holes.sorted { $0.number < $1.number }
        for (i, h) in remaining.enumerated() {
            h.number = i + 1
        }
        saveCourses()
        // The user's holes are keyed by number: every number below the last
        // now holds what the next hole held, and the last number goes.
        for h in remaining {
            SupabaseSync.shared.upsertMyCourseHole(h, courseId: course.id)
        }
        SupabaseSync.shared.deleteMyCourseHole(courseId: course.id, number: lastNumber)
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
        // Moving a hole makes it the user's own, shared or not.
        courses[courseIndex].holes[holeIndex].ownerId = currentUserUUID
        saveCourses()
        SupabaseSync.shared.upsertMyCourseHole(courses[courseIndex].holes[holeIndex], courseId: course.id)
        updateActiveRoundHoles(for: course)
    }

    func renumberHole(_ hole: Hole, in course: Course, newNumber: Int) {
        guard let courseIndex = courses.firstIndex(where: { $0.id == course.id }),
              canRenumberHoles(in: courses[courseIndex]) else { return }

        // SwiftData relationship arrays are unordered — work on a copy
        // sorted by current number, move the hole, then reassign.
        var sorted = courses[courseIndex].holes.sorted { $0.number < $1.number }
        guard let holeIndex = sorted.firstIndex(where: { $0.id == hole.id }) else { return }

        let clampedNumber = max(1, min(newNumber, sorted.count))
        let removedHole = sorted.remove(at: holeIndex)
        sorted.insert(removedHole, at: clampedNumber - 1)

        for (i, h) in sorted.enumerated() {
            h.number = i + 1
        }

        saveCourses()
        for h in sorted {
            SupabaseSync.shared.upsertMyCourseHole(h, courseId: course.id)
        }
        updateActiveRoundHoles(for: course)
    }


    // MARK: - Round Management

    func startRound(
        for course: Course,
        runHoleDetection: Bool = true,
        useHoleDetectionTestCoordinates: Bool = false,
        selectedTeeId: UUID? = nil
    ) -> Round {
        dprint("📱 [DataStore] startRound called for course: \(course.name)")
        // Auto-end any prior in-progress round — starting a new round
        // implies the old one is finished, regardless of whether the user
        // hit End Round. Avoids stale "ongoing" rounds piling up.
        endAnyOngoingRound(reason: "new round starting")
        // The round gets its own copies of the course's holes, as on the watch
        // and in `round_holes` (see `Round.holes`).
        let roundId = UUID()
        let round = Round(
            id: roundId,
            courseId: course.id,
            courseName: course.name,
            holes: course.holes.oneByNumber.map { $0.roundCopy(roundId: roundId, teeId: selectedTeeId) },
            holeDetectionEnabled: runHoleDetection,
            locationTestModeEnabled: useHoleDetectionTestCoordinates,
            selectedTeeId: selectedTeeId
        )
        rounds.append(round)
        saveRounds()

        // Round + clubs now sync via DB (Realtime + SwiftData) — no WC push needed.
        SupabaseSync.shared.upsertRound(round)
        SupabaseSync.shared.upsertRoundHoles(round)

        // Start path + altitude capture for the round. Hole-number provider
        // reads the round's currentHoleNumber live so each sample is tagged
        // with the hole the user is actually on at capture time.
        if let uid = AuthManager.shared.currentUserId {
            let roundId = round.id
            LocationManager.shared.startPathRecording(roundId: roundId, userId: uid) { [weak self] in
                guard let self,
                      let r = self.rounds.first(where: { $0.id == roundId }) else { return 1 }
                return r.currentHoleNumber
            }
        } else {
            ClientEventLogger.log("altitude.recording.skipped.noUid", detail: [
                "roundId": .string(round.id.uuidString)
            ])
        }

        // Live elevation-to-green readout. Load the cache for this
        // course's holes (one batched query) then start the readout
        // service so it'll publish a Δ as soon as enough crossings land.
        let elevationCourseId = course.id
        Task { @MainActor in
            await HoleHeightCellCache.shared.loadForCourse(courseId: elevationCourseId)
            ElevationReadout.shared.start(courseId: elevationCourseId)
            await HistoricalFirstStrokeCache.shared.loadForCourse(
                courseId: elevationCourseId
            )
        }

        if runHoleDetection {
            startHoleDetection(
                for: course,
                overrideCenter: useHoleDetectionTestCoordinates ? holeDetectionTestCenter : nil,
                allowCache: !useHoleDetectionTestCoordinates,
                persistResult: !useHoleDetectionTestCoordinates
            )
        }

        return round
    }

    // MARK: - GPS Round Start


    func pickTee(_ tee: CachedCourseTee?) {
        let resolution = pendingTeePickerResolution
        pendingTeePicker = nil
        pendingTeePickerResolution = nil
        guard let resolution else { return }
        startRound(from: resolution, selectedTeeId: tee?.id)
    }

    func handleResolved(_ resolution: RoundResolver.Resolution) {
        guard let scorecard = resolution.scorecardCourse else {
            startRound(from: resolution, selectedTeeId: nil)
            return
        }
        Task {
            let tees = (try? await GolfCourseAPIService.shared.cachedTees(
                forExternalCourseId: String(scorecard.id)
            )) ?? []
            await MainActor.run {
                if tees.isEmpty {
                    self.startRound(from: resolution, selectedTeeId: nil)
                } else {
                    self.pendingTeePickerResolution = resolution
                    self.pendingTeePicker = PendingTeePicker(
                        courseName: resolution.courseName,
                        tees: tees
                    )
                }
            }
        }
    }

    private func startRound(from resolution: RoundResolver.Resolution, selectedTeeId: UUID?) {
        Task { @MainActor in
            let course = await self.courseForRound(resolution)
            _ = self.startRound(for: course, runHoleDetection: resolution.tier != .full, selectedTeeId: selectedTeeId)
        }
    }

    /// The course a resolved round starts on: the local one, else the server's
    /// (with its hole rows), else a new one built from the resolution. Building
    /// a new local copy of a course the server already had gave every hole a
    /// second id: `holes` is unique on (course_id, number), so the server kept
    /// its own rows, and they arrived later as more holes.
    private func courseForRound(_ resolution: RoundResolver.Resolution) async -> Course {
        let osmEncoded = resolution.osmData.flatMap { try? JSONEncoder().encode($0) }
        var found = courses.first(where: { $0.id == resolution.courseId })
        if found == nil {
            found = await fetchAndInsertCourse(by: resolution.courseId)
        }
        let isNew = found == nil
        let course = found ?? Course(
            id: resolution.courseId,
            name: resolution.courseName,
            centerLat: resolution.courseCoordinate.latitude,
            centerLon: resolution.courseCoordinate.longitude,
            osmPolygons: osmEncoded
        )
        if let osmEncoded { course.osmPolygons = osmEncoded }
        if course.holes.isEmpty, resolution.tier == .full, let osm = resolution.osmData {
            course.holes = osm.holes
                .compactMap { h -> Hole? in
                    guard let ref = h.ref, let n = Int(ref) else { return nil }
                    return Hole(
                        number: n,
                        coordinate: CLLocationCoordinate2D(
                            latitude: h.greenPoint.latitude,
                            longitude: h.greenPoint.longitude
                        ),
                        par: h.par
                    )
                }
                .sorted { $0.number < $1.number }
            // These are OSM's holes, so the server builds the shared rows
            // itself. For a new course the resolver asks it once the course
            // row exists.
            if !isNew {
                SupabaseSync.shared.deriveOSMCourseHoles(courseId: course.id)
            }
        }
        if isNew {
            courses.append(course)
        }
        saveCourses()
        if isNew {
            SupabaseSync.shared.upsertCourse(course)
        }
        return course
    }

    /// Start a round with no GPS fix at all. The user still names the course,
    /// but with no coordinate there's nothing to anchor it to, so it can't be
    /// matched by proximity next time. This used to silently create a course
    /// called "Quick Start" — one per tap, each showing up in Stats as its own
    /// venue.
    func startManualQuickRound() {
        pendingCourseNameCompletion = { [weak self] entered in
            guard let self = self else { return }
            let name = (entered ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }   // cancelled — no round
            let newCourse = Course(name: name)
            self.courses.append(newCourse)
            self.saveCourses()
            SupabaseSync.shared.upsertCourse(newCourse)
            _ = self.startRound(for: newCourse, runHoleDetection: false)
        }
        pendingCourseNamePrompt = true
    }

    private func startHoleDetection(
        for course: Course,
        overrideCenter: CLLocationCoordinate2D? = nil,
        allowCache: Bool = true,
        persistResult: Bool = true
    ) {
        if holeDetectionRunStateByCourse[course.id]?.isRunning == true {
            // A re-request mid-run still gets an answer.
            WatchConnectivityManager.shared.sendHoleDetectionStatus(courseId: course.id, state: .running)
            return
        }

        if allowCache, let cached = holeDetectionDataByCourse[course.id] {
            dprint("📱 [DataStore] Using cached hole detection data (\(cached.blobs.count) blobs)")
            holeDetectionRunStateByCourse[course.id] = HoleDetectionRunState(
                isRunning: false,
                message: "Hole detection ready",
                progress: 1.0,
                error: nil
            )
            WatchConnectivityManager.shared.sendHoleDetectionData(cached)
            finishHoleDetection(courseId: course.id, state: .done)
            return
        }

        // Server-side cache: courses.blob_detection_results. If a previous
        // run (any device, any user) already analyzed this course, fetch
        // and reuse instead of running the analyzer locally. The fetch is
        // async; on miss we re-call ourselves with allowCache=false so the
        // analyzer code path runs synchronously. On hit we ship and return.
        if allowCache {
            let courseId = course.id
            let overrideCenterLocal = overrideCenter
            Task { @MainActor in
                if let serverCached = await self.fetchBlobDetectionResults(courseId: courseId) {
                    self.holeDetectionDataByCourse[courseId] = serverCached
                    self.saveHoleDetectionData()
                    self.holeDetectionRunStateByCourse[courseId] = HoleDetectionRunState(
                        isRunning: false,
                        message: "Hole detection ready (cached)",
                        progress: 1.0,
                        error: nil
                    )
                    WatchConnectivityManager.shared.sendHoleDetectionData(serverCached)
                    ClientEventLogger.log("blob.serverCache.hit", detail: [
                        "courseId": .string(courseId.uuidString),
                        "blobCount": .integer(serverCached.blobs.count)
                    ])
                    self.finishHoleDetection(courseId: courseId, state: .done)
                } else {
                    ClientEventLogger.log("blob.serverCache.miss", detail: [
                        "courseId": .string(courseId.uuidString)
                    ])
                    self.startHoleDetection(
                        for: course,
                        overrideCenter: overrideCenterLocal,
                        allowCache: false,
                        persistResult: persistResult
                    )
                }
            }
            return
        }

        // The course's own stored center comes before this phone's GPS. A
        // queued watch request can run hours after it was made, wherever the
        // phone happens to be when the app is next opened, and centering on
        // the phone then scans the wrong place entirely. Placed holes still
        // win — they are where the greens actually are.
        let storedCenter: CLLocationCoordinate2D? = {
            guard let lat = course.centerLat, let lon = course.centerLon else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }()
        let resolvedCenter: (coordinate: CLLocationCoordinate2D, source: String)? = {
            if let c = overrideCenter { return (c, "override") }
            if let c = calculateCourseCentroid(course: course) { return (c, "holes") }
            if let c = storedCenter { return (c, "courseRecord") }
            if let c = LocationManager.shared.getCurrentLocation()?.coordinate { return (c, "phoneGPS") }
            return nil
        }()
        guard let resolvedCenter else {
            holeDetectionRunStateByCourse[course.id] = HoleDetectionRunState(
                isRunning: false,
                message: "Hole detection unavailable",
                progress: 0,
                error: "No location available"
            )
            ClientEventLogger.log("blob.analyzer.noCenter", detail: [
                "courseId": .string(course.id.uuidString)
            ])
            finishHoleDetection(courseId: course.id, state: .failed)
            return
        }
        let center = resolvedCenter.coordinate

        let coverageRadius = holeDetectionCoverageRadius(for: course, center: center)
        // Decode the OSM bounding polygon(s) if we have them — used to gate
        // blob detection so two courses on the same property (Stonegate
        // Cypress vs Oaks) don't cross-contaminate. Old courses rows
        // without `boundingPolygons` (pre-fix) decode to nil and the
        // analyzer falls back to the radius-only behavior.
        let boundingPolygons: [[CLLocationCoordinate2D]]? = {
            guard let data = course.osmPolygons,
                  let osm = try? JSONDecoder().decode(OSMCourseData.self, from: data),
                  let polys = osm.boundingPolygons, !polys.isEmpty else { return nil }
            return polys.map { $0.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } }
        }()
        holeDetectionRunStateByCourse[course.id] = HoleDetectionRunState(
            isRunning: true,
            message: "Starting hole detection...",
            progress: 0,
            error: nil
        )
        let courseIdForTask = course.id
        holeDetectionBackgroundTasks[course.id] = UIApplication.shared.beginBackgroundTask(withName: "holeDetection") { [weak self] in
            // Out of background time before the run finished. The analyzer
            // cannot be cancelled, so its completion still fires later; this
            // only returns the task so the app is not terminated for holding it.
            guard let self, let task = self.holeDetectionBackgroundTasks.removeValue(forKey: courseIdForTask) else { return }
            ClientEventLogger.log("blob.analyzer.backgroundExpired", detail: [
                "courseId": .string(courseIdForTask.uuidString)
            ])
            UIApplication.shared.endBackgroundTask(task)
        }
        WatchConnectivityManager.shared.sendHoleDetectionStatus(courseId: course.id, state: .running)
        ClientEventLogger.log("blob.analyzer.started", detail: [
            "courseId": .string(course.id.uuidString),
            "centerSource": .string(resolvedCenter.source),
            "coverageRadiusMeters": .double(coverageRadius)
        ])

        holeDetectionAnalyzer.detect(
            courseId: course.id,
            center: center,
            coverageRadiusMeters: coverageRadius,
            boundingPolygons: boundingPolygons,
            progress: { [weak self] message, progress in
                DispatchQueue.main.async {
                    self?.holeDetectionRunStateByCourse[course.id] = HoleDetectionRunState(
                        isRunning: true,
                        message: message,
                        progress: progress,
                        error: nil
                    )
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .success(let output):
                        let detectionData = output.data
                        dprint("📱 [DataStore] Hole detection diagnostics: tiles=\(output.diagnostics.tileCount), greenPx=\(output.diagnostics.totalGreenPixels), greenishPx=\(output.diagnostics.totalGreenishPixels), swappedExactPx=\(output.diagnostics.totalSwappedChannelExactPixels), preMergeBlobs=\(output.diagnostics.preMergeBlobCount), mergedBlobs=\(output.diagnostics.mergedBlobCount)")
                        if output.diagnostics.topGreenishColors.isEmpty {
                            dprint("📱 [DataStore] Hole detection top green-ish RGBs: none above threshold")
                        } else {
                            let colors = output.diagnostics.topGreenishColors.map(\.formatted).joined(separator: " | ")
                            dprint("📱 [DataStore] Hole detection top green-ish RGBs: \(colors)")
                        }
                        // Keep detection results in memory for current-round UI even when test runs are non-persistent.
                        self.holeDetectionDataByCourse[course.id] = detectionData
                        if persistResult {
                            self.saveHoleDetectionData()
                            // Server-side persistence — write to courses
                            // table so any device picking up this round
                            // (or another user playing the same course)
                            // skips the analyzer.
                            self.uploadBlobDetectionResults(courseId: course.id, data: detectionData)
                        }
                        self.holeDetectionRunStateByCourse[course.id] = HoleDetectionRunState(
                            isRunning: false,
                            message: output.diagnostics.summaryMessage,
                            progress: 1.0,
                            error: nil
                        )
                        WatchConnectivityManager.shared.sendHoleDetectionData(detectionData)
                        ClientEventLogger.log("blob.analyzer.succeeded", detail: [
                            "courseId": .string(course.id.uuidString),
                            "tileCount": .integer(output.diagnostics.tileCount),
                            "blobCount": .integer(detectionData.blobs.count)
                        ])
                        // Persisted runs report `done` from the upload, once
                        // the server cache actually holds the result.
                        if !persistResult {
                            self.finishHoleDetection(courseId: course.id, state: .done)
                        }
                    case .failure(let error):
                        self.holeDetectionRunStateByCourse[course.id] = HoleDetectionRunState(
                            isRunning: false,
                            message: "Hole detection failed",
                            progress: 0,
                            error: error.localizedDescription
                        )
                        let tileErrors = (error as? HoleDetectionAllTilesFailed)?.errors ?? [error]
                        ClientEventLogger.log("blob.analyzer.failed", detail: [
                            "courseId": .string(course.id.uuidString),
                            "tileErrorCount": .integer(tileErrors.count),
                            "errors": .string(Set(tileErrors.map(Self.describe)).sorted().joined(separator: " | "))
                        ])
                        self.finishHoleDetection(courseId: course.id, state: .failed)
                    }
                }
            }
        )
    }

    private func holeDetectionCoverageRadius(for course: Course, center: CLLocationCoordinate2D) -> Double {
        let coords = course.holes.compactMap { $0.coordinate }
        guard !coords.isEmpty else {
            return 2800
        }

        let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let maxDistance = coords.map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: centerLocation)
        }.max() ?? 0

        return max(1800, maxDistance + 800)
    }

    private func calculateCourseCentroid(course: Course) -> CLLocationCoordinate2D? {
        let holesWithCoords = course.holes.compactMap { $0.coordinate }
        guard !holesWithCoords.isEmpty else { return nil }
        let avgLat = holesWithCoords.map { $0.latitude }.reduce(0, +) / Double(holesWithCoords.count)
        let avgLon = holesWithCoords.map { $0.longitude }.reduce(0, +) / Double(holesWithCoords.count)
        return CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
    }

    func addStroke(to round: Round, holeNumber: Int, coordinate: CLLocationCoordinate2D, clubId: UUID, trajectoryHeading: Double? = nil) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }) else { return }

        let strokeNumber = Stroke.nextStrokeNumber(in: rounds[roundIndex], holeNumber: holeNumber)

        let stroke = Stroke(
            holeNumber: holeNumber,
            strokeNumber: strokeNumber,
            coordinate: coordinate,
            clubId: clubId,
            trajectoryHeading: trajectoryHeading,
            relAltMeters: LocationManager.shared.currentRelativeAltitudeMeters
        )
        rounds[roundIndex].strokes.append(stroke)
        saveRounds()

        // Mirror to Supabase (Realtime fans out to the other device)
        SupabaseSync.shared.upsertStroke(stroke, roundId: round.id)
        SupabaseSync.shared.upsertRound(rounds[roundIndex])
    }

    func deleteRound(_ round: Round) {
        let wasInProgress = round.endedAt == nil
        rounds.removeAll { $0.id == round.id }
        // Delete from SwiftData too, not just the published array. Without
        // this the row survives in the store and `loadRounds()` re-fetches it
        // on the next launch — the round only really disappeared when the
        // Supabase delete echoed back through Realtime's `applyRound(.delete)`,
        // so deleting offline (or missing the event) resurrected it.
        // Cascade takes the round's strokes, targets and holes; the holes are
        // the round's own copies, never the course's.
        if let context = context {
            context.delete(round)
        }
        saveRounds()
        SupabaseSync.shared.deleteRound(id: round.id)
        rebuildPlayerStats()
        if currentRoundId == round.id { currentRoundId = nil }

        // Deleting an in-progress round needs the same teardown as endRound,
        // minus the elevation fold-in (the round's data is being discarded).
        if wasInProgress {
            Task { @MainActor in
                ElevationReadout.shared.stop()
                HoleHeightCellCache.shared.clear()
                HistoricalFirstStrokeCache.shared.clear()
            }
            Task {
                await LocationManager.shared.stopPathRecording()
            }
        }
    }

    /// Replace the target markers for one hole of a round. Owns both the
    /// local mutation and the Supabase mirror (including deletes for
    /// removed targets, which the blanket round upsert never covered).
    func setTargets(for round: Round, holeNumber: Int, coordinates: [CLLocationCoordinate2D]) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }) else { return }

        let removed = rounds[roundIndex].targets.filter { $0.holeNumber == holeNumber }
        rounds[roundIndex].targets.removeAll { $0.holeNumber == holeNumber }

        let newTargets = coordinates.map { Target(holeNumber: holeNumber, coordinate: $0) }
        rounds[roundIndex].targets.append(contentsOf: newTargets)
        saveRounds()

        for target in removed {
            SupabaseSync.shared.deleteTarget(id: target.id)
        }
        for target in newTargets {
            SupabaseSync.shared.upsertTarget(target, roundId: round.id)
        }
    }

    func hasRounds(for course: Course) -> Bool {
        return rounds.contains { $0.courseId == course.id }
    }

    // MARK: - Demo Data

    /// Adds a fixed set of fake courses + rounds so visualizations have
    /// something to render. Idempotent — running twice replaces prior demo data.
    func seedDemoData() {
        clearDemoData()
        let generated = DemoDataSeeder.generate(
            clubTypes: clubTypes,
            availableClubs: availableClubs
        )
        courses.append(contentsOf: generated.courses)
        rounds.append(contentsOf: generated.rounds)
        saveCourses()
        saveRounds()
        for course in generated.courses {
            SupabaseSync.shared.upsertCourse(course)
            for hole in course.holes {
                hole.ownerId = currentUserUUID
                SupabaseSync.shared.upsertMyCourseHole(hole, courseId: course.id)
            }
        }
        for round in generated.rounds {
            SupabaseSync.shared.upsertRound(round)
            SupabaseSync.shared.upsertRoundHoles(round)
            for stroke in round.strokes {
                SupabaseSync.shared.upsertStroke(stroke, roundId: round.id)
            }
        }
        rebuildPlayerStats()
    }

    /// Removes any course whose name starts with the demo prefix, along with
    /// all rounds tied to those courses. Leaves real data alone.
    func clearDemoData() {
        let demoCourseIds = Set(
            courses.filter { $0.name.hasPrefix(DemoDataSeeder.demoPrefix) }.map { $0.id }
        )
        guard !demoCourseIds.isEmpty else { return }
        let demoRoundIds = rounds.filter { demoCourseIds.contains($0.courseId) }.map { $0.id }
        rounds.removeAll { demoCourseIds.contains($0.courseId) }
        courses.removeAll { demoCourseIds.contains($0.id) }
        saveCourses()
        saveRounds()
        // Server cascades clean up child rows (strokes, holes, targets).
        for id in demoRoundIds {
            SupabaseSync.shared.deleteRound(id: id)
        }
        for id in demoCourseIds {
            SupabaseSync.shared.deleteCourse(id: id)
        }
        rebuildPlayerStats()
    }

    func updateStrokePosition(in round: Round, stroke: Stroke, newCoordinate: CLLocationCoordinate2D) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }),
              let strokeIndex = rounds[roundIndex].strokes.firstIndex(where: { $0.id == stroke.id }) else { return }

        rounds[roundIndex].strokes[strokeIndex].latitude = newCoordinate.latitude
        rounds[roundIndex].strokes[strokeIndex].longitude = newCoordinate.longitude

        saveRounds()
        SupabaseSync.shared.upsertStroke(rounds[roundIndex].strokes[strokeIndex], roundId: round.id)
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
        SupabaseSync.shared.deleteStroke(id: stroke.id)

        // Mirror to Supabase (Realtime fans out to the other device).
        // The surviving strokes on this hole were renumbered above.
        for s in rounds[roundIndex].strokes where s.holeNumber == holeNumber {
            SupabaseSync.shared.upsertStroke(s, roundId: round.id)
        }
        SupabaseSync.shared.upsertRound(rounds[roundIndex])
    }

    func addPenaltyStroke(to round: Round, holeNumber: Int, coordinate: CLLocationCoordinate2D, clubId: UUID) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }) else { return }

        let strokesForHole = rounds[roundIndex].strokes.filter { $0.holeNumber == holeNumber }
        let strokeNumber = strokesForHole.count + 1

        let stroke = Stroke(
            holeNumber: holeNumber,
            strokeNumber: strokeNumber,
            coordinate: coordinate,
            clubId: clubId,
            isPenalty: true,
            relAltMeters: LocationManager.shared.currentRelativeAltitudeMeters
        )
        rounds[roundIndex].strokes.append(stroke)
        saveRounds()

        // Mirror to Supabase (Realtime fans out to the other device)
        SupabaseSync.shared.upsertStroke(stroke, roundId: round.id)
        SupabaseSync.shared.upsertRound(rounds[roundIndex])
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
        for s in rounds[roundIndex].strokes where s.holeNumber == holeNumber {
            SupabaseSync.shared.upsertStroke(s, roundId: round.id)
        }
    }

    // MARK: - Round State Management (with automatic sync)

    func setCurrentHole(for round: Round, number: Int) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }) else { return }

        rounds[roundIndex].currentHoleNumber = number
        rounds[roundIndex].lastActivityAt = Date()
        saveRounds()
        ClientEventLogger.logBattery(hole: number)

        // Mirror to Supabase (Realtime fans out to the other device)
        SupabaseSync.shared.updateCurrentHole(rounds[roundIndex])
    }

    /// Mark a round finished. Manual button + lifecycle sweep both call this.
    /// Idempotent: setting `endedAt` on an already-ended round is a no-op.
    func endRound(_ round: Round, reason: String = "manual") {
        guard let idx = rounds.firstIndex(where: { $0.id == round.id }) else { return }
        guard rounds[idx].endedAt == nil else { return }
        rounds[idx].endedAt = Date()
        saveRounds()
        dprint("📱 [DataStore] Ended round \(round.id) — \(reason)")
        SupabaseSync.shared.upsertRound(rounds[idx])
        // Drain the upload queue in the background; queue is disk-
        // persistent so the next round picks up any leftovers. After the
        // drain completes, fold this round's altitude rows into the
        // shared `hole_height_cells` table so future rounds (anyone's)
        // can calibrate against them.
        let foldInCourseId = rounds[idx].courseId
        let foldInRoundId = rounds[idx].id
        let skipFoldIn = rounds[idx].locationTestModeEnabled == true
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
        if currentRoundId == round.id { currentRoundId = nil }
    }

    /// End every in-progress round. Used by startRound — once the user
    /// starts a new round, any prior open round is implicitly over.
    func endAnyOngoingRound(reason: String) {
        for r in rounds where r.endedAt == nil {
            endRound(r, reason: reason)
        }
    }

    func completeHole(in round: Round, holeNumber: Int) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }) else { return }

        rounds[roundIndex].completedHoles.insert(holeNumber)
        saveRounds()

        // Mirror to Supabase (Realtime fans out to the other device)
        SupabaseSync.shared.upsertRound(rounds[roundIndex])
    }

    func reopenHole(in round: Round, holeNumber: Int) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }) else { return }

        rounds[roundIndex].completedHoles.remove(holeNumber)
        saveRounds()

        // Mirror to Supabase (Realtime fans out to the other device)
        SupabaseSync.shared.upsertRound(rounds[roundIndex])
    }
}

extension DataStore: RoundStoreShared {
    func endRoundForLifecycle(_ round: Round, reason: String) {
        endRound(round, reason: reason)
    }

    func adoptServerActivity(_ date: Date, for round: Round) {
        guard let idx = rounds.firstIndex(where: { $0.id == round.id }) else { return }
        rounds[idx].lastActivityAt = date
        saveRounds()
    }

    func refreshAfterReconcile() {}

    var requestsLocationOnRoundStart: Bool { true }
}
