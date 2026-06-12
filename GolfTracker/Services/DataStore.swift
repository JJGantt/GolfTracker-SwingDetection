import Foundation
import CoreLocation
import MapKit
import SwiftData

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

    struct PendingScorecardPicker: Identifiable {
        var id = UUID()
        let originalName: String
        let candidates: [RoundResolver.ScorecardCandidate]
    }

    struct PendingTeePicker: Identifiable {
        var id = UUID()
        let courseName: String
        let tees: [CachedCourseTee]
    }

    @Published var roundStartStatus: String?
    @Published var pendingCoursePicker: [RoundResolver.CourseCandidate]?
    private var pendingCoursePickerCompletion: ((RoundResolver.CourseCandidate?) -> Void)?
    @Published var pendingScorecardPicker: PendingScorecardPicker?
    private var pendingScorecardPickerCompletion: ((GCAPICourse?) -> Void)?
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

    private var lifecycleTimer: Timer?

    /// 60s timer evaluating any in-progress round against the inactivity
    /// (>1h) and off-course (>2km) gates. Mirrors WatchDataStore's sweep so
    /// rounds end correctly regardless of which device is active.
    private func startRoundLifecycleSweep() {
        lifecycleTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.evaluateRoundLifecycle()
        }
        RunLoop.main.add(timer, forMode: .common)
        lifecycleTimer = timer
        evaluateRoundLifecycle()
    }

    private func evaluateRoundLifecycle() {
        guard let round = currentRound else { return }
        // Test mode: skip the off-course branch by passing nil location.
        // Simulated GPS would otherwise be >2km from real hole coords and
        // auto-end every test round.
        let location = LocationManager.shared.isTestModeEnabled
            ? nil
            : LocationManager.shared.location?.coordinate
        let decision = RoundLifecycleEvaluator.evaluate(
            round: round,
            location: location
        )
        guard decision.shouldEnd else { return }
        if RoundLifecycleEvaluator.isInactivityReason(decision.reason) {
            // Local lastActivityAt may be stale (other device was the writer
            // while we were backgrounded) — verify against the server before
            // ending. Offline → server unreachable → trust local, as before.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let fresh = await RoundLifecycleEvaluator.serverLastActivityAt(roundId: round.id),
                   Date().timeIntervalSince(fresh) <= RoundLifecycleEvaluator.inactivityThreshold {
                    if let idx = self.rounds.firstIndex(where: { $0.id == round.id }) {
                        self.rounds[idx].lastActivityAt = fresh
                        self.saveRounds()
                    }
                    return
                }
                self.endRound(round, reason: decision.reason ?? "lifecycle")
            }
        } else {
            endRound(round, reason: decision.reason ?? "lifecycle")
        }
    }

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
                guard let course = course else { return }
                self.runHoleDetection(for: course)
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
        }
    }

    func runHoleDetection(for course: Course) {
        startHoleDetection(for: course, allowCache: true, persistResult: true)
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
    func configure(container: ModelContainer) {
        self.modelContainer = container
        self.sharedContext = ModelContext(container)
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
                context.insert(ClubTypeData(id: id, name: t.name, isDefault: t.is_default ?? false, averageDistance: t.average_distance))
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
            clubs: availableClubs,
            clubTypes: clubTypes
        )
        savePlayerStats()
        dprint("📊 Player stats rebuilt: \(rounds.count) rounds, \(playerStats.perClubTypeStats.count) club types")
    }

    func loadClubTypes() {
        guard let context = context else { return }
        clubTypes = (try? context.fetch(FetchDescriptor<ClubTypeData>())) ?? []
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

    /// Resolve the displayable type name for a club. Mirrors
    /// WatchDataStore so cross-target callers (HoleMapView's putt count)
    /// have the same API on both platforms.
    func getTypeName(for club: ClubData) -> String {
        clubTypes.first { $0.id == club.clubTypeId }?.name ?? club.name
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

    /// Source-agnostic green candidates for a course — OSM polygons
    /// (when present) merged with blob-detection results passing the
    /// active filter settings. Mirrors the watch's
    /// `WatchDataStore.filteredGreenCandidates`. Drives map polygon
    /// rendering, the on-green color flip, and any other "where is the
    /// green for hole N" lookup.
    func filteredGreenCandidates(for courseId: UUID?) -> [HoleDetectionBlob] {
        guard let courseId else { return [] }
        var out: [HoleDetectionBlob] = []
        if let osm = osmCourseData(forCourseId: courseId) {
            out.append(contentsOf: osm.greens.map(Self.blob(fromOSMGreen:)))
        }
        if let detectionData = holeDetectionDataByCourse[courseId] {
            out.append(contentsOf: holeFilterSettings.apply(to: detectionData.blobs))
        }
        return out
    }

    /// Convert an OSM green polygon to the `HoleDetectionBlob` shape the
    /// rest of the picker/map code consumes. Filter fields set high so
    /// the OSM polygon always passes — it's mapper-curated, not
    /// heuristic-detected. Same shape as watch's helper.
    private static func blob(fromOSMGreen polygon: OSMPolygon) -> HoleDetectionBlob {
        let avgLat = polygon.points.map(\.latitude).reduce(0, +) / Double(max(polygon.points.count, 1))
        let avgLon = polygon.points.map(\.longitude).reduce(0, +) / Double(max(polygon.points.count, 1))
        return HoleDetectionBlob(
            id: UUID(),
            area: 9_999,
            minWidth: 999,
            elongation: 1.0,
            greennessScore: 9_999,
            centroidLatitude: avgLat,
            centroidLongitude: avgLon,
            polygon: polygon.points
        )
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
        courses[index].holes.append(hole)
        saveCourses()
        SupabaseSync.shared.upsertHole(hole, courseId: course.id)

        dprint("📱 [DataStore] Added hole #\(holeNumber) to course \(course.name)")

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
                dprint("📱 [DataStore] New hole added, updated currentHoleIndex to \(rounds[roundIndex].currentHoleIndex)")
            }

            saveRounds()

            SupabaseSync.shared.upsertRound(rounds[roundIndex])
        }
    }

    func deleteHole(_ hole: Hole, from course: Course) {
        guard let courseIndex = courses.firstIndex(where: { $0.id == course.id }) else { return }
        courses[courseIndex].holes.removeAll { $0.id == hole.id }
        // Renumber remaining holes. SwiftData relationship arrays are
        // unordered — sort by current number before reassigning.
        let remaining = courses[courseIndex].holes.sorted { $0.number < $1.number }
        for (i, h) in remaining.enumerated() {
            h.number = i + 1
        }
        saveCourses()
        SupabaseSync.shared.deleteHole(id: hole.id)
        // The renumbered siblings changed too — push them to the holes table.
        for h in remaining {
            SupabaseSync.shared.upsertHole(h, courseId: course.id)
        }
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
        SupabaseSync.shared.upsertHole(courses[courseIndex].holes[holeIndex], courseId: course.id)
        updateActiveRoundHoles(for: course)
    }

    func renumberHole(_ hole: Hole, in course: Course, newNumber: Int) {
        guard let courseIndex = courses.firstIndex(where: { $0.id == course.id }) else { return }

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
            SupabaseSync.shared.upsertHole(h, courseId: course.id)
        }
        updateActiveRoundHoles(for: course)
    }


    // MARK: - Round Management

    func startRound(
        for course: Course,
        runHoleDetection: Bool = true,
        useHoleDetectionTestCoordinates: Bool = false
    ) -> Round {
        dprint("📱 [DataStore] startRound called for course: \(course.name)")
        // Auto-end any prior in-progress round — starting a new round
        // implies the old one is finished, regardless of whether the user
        // hit End Round. Avoids stale "ongoing" rounds piling up.
        endAnyOngoingRound(reason: "new round starting")
        let round = Round(
            courseId: course.id,
            courseName: course.name,
            holes: course.holes,
            holeDetectionEnabled: runHoleDetection,
            locationTestModeEnabled: useHoleDetectionTestCoordinates
        )
        rounds.append(round)
        saveRounds()

        // Round + clubs now sync via DB (Realtime + SwiftData) — no WC push needed.
        SupabaseSync.shared.upsertRound(round)

        // Start path + altitude capture for the round. Hole-number provider
        // reads the round's currentHoleIndex live so each sample is tagged
        // with the hole the user is actually on at capture time.
        if let uid = AuthManager.shared.currentUserId {
            let roundId = round.id
            LocationManager.shared.startPathRecording(roundId: roundId, userId: uid) { [weak self] in
                guard let self,
                      let r = self.rounds.first(where: { $0.id == roundId }) else { return 1 }
                let sorted = r.holes.sorted { $0.number < $1.number }
                let idx = max(0, min(r.currentHoleIndex, sorted.count - 1))
                return sorted.indices.contains(idx) ? sorted[idx].number : 1
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
        let holeNumbers = round.holes.map { $0.number }
        Task { @MainActor in
            await HoleHeightCellCache.shared.loadForCourse(
                courseId: elevationCourseId, holeNumbers: holeNumbers
            )
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

    func startRoundAtCurrentLocation() {
        guard let coordinate = LocationManager.shared.location?.coordinate else {
            startManualQuickRound()
            return
        }
        roundStartStatus = "Locating…"
        RoundResolver.shared.resolve(
            at: coordinate,
            progress: { [weak self] step in
                DispatchQueue.main.async { self?.roundStartStatus = Self.statusString(for: step) }
            },
            coursePicker: { [weak self] candidates, choose in
                DispatchQueue.main.async {
                    self?.pendingCoursePicker = candidates
                    self?.pendingCoursePickerCompletion = choose
                }
            },
            scorecardPicker: { [weak self] originalName, ranked, choose in
                DispatchQueue.main.async {
                    self?.pendingScorecardPicker = PendingScorecardPicker(originalName: originalName, candidates: ranked)
                    self?.pendingScorecardPickerCompletion = choose
                }
            },
            completion: { [weak self] resolution in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.roundStartStatus = nil
                    if let resolution {
                        self.handleResolved(resolution)
                    } else {
                        self.startManualQuickRound()
                    }
                }
            }
        )
    }

    func pickCourseCandidate(_ candidate: RoundResolver.CourseCandidate?) {
        let completion = pendingCoursePickerCompletion
        pendingCoursePicker = nil
        pendingCoursePickerCompletion = nil
        completion?(candidate)
    }

    func pickScorecardCandidate(_ candidate: GCAPICourse?) {
        let completion = pendingScorecardPickerCompletion
        pendingScorecardPicker = nil
        pendingScorecardPickerCompletion = nil
        completion?(candidate)
    }

    func pickTee(_ tee: CachedCourseTee?) {
        let resolution = pendingTeePickerResolution
        pendingTeePicker = nil
        pendingTeePickerResolution = nil
        guard let resolution else { return }
        startRound(from: resolution, selectedTeeId: tee?.id)
    }

    private func handleResolved(_ resolution: RoundResolver.Resolution) {
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
        let course: Course
        if let existing = courses.first(where: { $0.id == resolution.courseId }) {
            course = existing
            if let osm = resolution.osmData, let encoded = try? JSONEncoder().encode(osm) {
                course.osmPolygons = encoded
                try? context?.save()
            }
        } else {
            let osmEncoded = resolution.osmData.flatMap { try? JSONEncoder().encode($0) }
            let newCourse = Course(
                id: resolution.courseId,
                name: resolution.courseName,
                centerLat: resolution.courseCoordinate.latitude,
                centerLon: resolution.courseCoordinate.longitude,
                osmPolygons: osmEncoded
            )
            if resolution.tier == .full, let osm = resolution.osmData {
                newCourse.holes = osm.holes
                    .compactMap { h -> Hole? in
                        guard let ref = h.ref, let n = Int(ref) else { return nil }
                        return Hole(
                            number: n,
                            coordinate: CLLocationCoordinate2D(
                                latitude: h.greenPoint.latitude,
                                longitude: h.greenPoint.longitude
                            ),
                            par: h.par,
                            teeId: selectedTeeId
                        )
                    }
                    .sorted { $0.number < $1.number }
            }
            courses.append(newCourse)
            saveCourses()
            SupabaseSync.shared.upsertCourse(newCourse)
            course = newCourse
        }
        _ = startRound(for: course, runHoleDetection: resolution.tier != .full)
    }

    func startManualQuickRound() {
        let newCourse = Course(name: "Quick Start")
        courses.append(newCourse)
        saveCourses()
        SupabaseSync.shared.upsertCourse(newCourse)
        _ = startRound(for: newCourse, runHoleDetection: false)
    }

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

    private func startHoleDetection(
        for course: Course,
        overrideCenter: CLLocationCoordinate2D? = nil,
        allowCache: Bool = true,
        persistResult: Bool = true
    ) {
        if holeDetectionRunStateByCourse[course.id]?.isRunning == true {
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

        guard let center = overrideCenter
                ?? calculateCourseCentroid(course: course)
                ?? LocationManager.shared.getCurrentLocation()?.coordinate
                ?? course.holes.first?.coordinate else {
            holeDetectionRunStateByCourse[course.id] = HoleDetectionRunState(
                isRunning: false,
                message: "Hole detection unavailable",
                progress: 0,
                error: "No location available"
            )
            return
        }

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
                    case .failure(let error):
                        self.holeDetectionRunStateByCourse[course.id] = HoleDetectionRunState(
                            isRunning: false,
                            message: "Hole detection failed",
                            progress: 0,
                            error: error.localizedDescription
                        )
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
        }
        for round in generated.rounds {
            SupabaseSync.shared.upsertRound(round)
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

    func updateCurrentHoleIndex(for round: Round, newIndex: Int) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }) else { return }

        rounds[roundIndex].currentHoleIndex = newIndex
        rounds[roundIndex].lastActivityAt = Date()
        saveRounds()

        // Mirror to Supabase (Realtime fans out to the other device)
        SupabaseSync.shared.upsertRound(rounds[roundIndex])
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

    // MARK: - Club Type Management

    func addClubType(name: String) {
        let clubType = ClubTypeData(name: name, isDefault: false)
        clubTypes.append(clubType)
        saveClubTypes()
        dprint("🏌️ Added club type: \(name), total types: \(clubTypes.count)")
    }

    func deleteClubType(_ clubType: ClubTypeData) {
        // Don't allow deleting default types
        guard !clubType.isDefault else { return }

        let removedClubIds = availableClubs.filter { $0.clubTypeId == clubType.id }.map { $0.id }
        clubTypes.removeAll { $0.id == clubType.id }

        // Remove all clubs that use this type
        availableClubs.removeAll { $0.clubTypeId == clubType.id }

        saveClubTypes()
        saveClubs()
        SupabaseSync.shared.deleteClubType(id: clubType.id)
        for id in removedClubIds { SupabaseSync.shared.deleteClub(id: id) }
    }

    func getClubType(byId id: UUID) -> ClubTypeData? {
        return clubTypes.first { $0.id == id }
    }

    func updateClubType(_ clubType: ClubTypeData, name: String) {
        guard let index = clubTypes.firstIndex(where: { $0.id == clubType.id }) else { return }
        clubTypes[index].name = name
        saveClubTypes()
    }

    func moveClubType(from source: IndexSet, to destination: Int) {
        clubTypes.move(fromOffsets: source, toOffset: destination)
        saveClubTypes()
    }

    // MARK: - Club Management

    func addCustomClub(name: String, clubTypeId: UUID) {
        let club = ClubData(name: name, clubTypeId: clubTypeId, isDefault: false)
        availableClubs.append(club)
        saveClubs()
    }

    func addCustomClubReturningId(name: String, clubTypeId: UUID) -> UUID {
        let club = ClubData(name: name, clubTypeId: clubTypeId, isDefault: false)
        availableClubs.append(club)
        saveClubs()
        return club.id
    }

    func updateClub(_ club: ClubData, name: String, clubTypeId: UUID) {
        guard let index = availableClubs.firstIndex(where: { $0.id == club.id }) else { return }
        availableClubs[index].name = name
        availableClubs[index].clubTypeId = clubTypeId
        saveClubs()
    }

    func moveClub(from source: IndexSet, to destination: Int) {
        availableClubs.move(fromOffsets: source, toOffset: destination)
        saveClubs()
    }

    func deleteClub(_ club: ClubData) {
        // Don't allow deleting default clubs
        guard !club.isDefault else { return }

        availableClubs.removeAll { $0.id == club.id }

        // Clear active club in any sets that used this club
        for i in 0..<clubSets.count {
            for j in 0..<clubSets[i].typeSelections.count {
                if clubSets[i].typeSelections[j].activeClubId == club.id {
                    clubSets[i].typeSelections[j].activeClubId = nil
                }
            }
        }

        saveClubs()
        saveClubSets()
        SupabaseSync.shared.deleteClub(id: club.id)
    }

    func getClub(byId id: UUID) -> ClubData? {
        return availableClubs.first { $0.id == id }
    }

    func getClubs(forType typeId: UUID) -> [ClubData] {
        return availableClubs.filter { $0.clubTypeId == typeId }
    }

    // MARK: - Club Set Management

    func addClubSet(name: String, typeSelections: [TypeSelection]) {
        let clubSet = ClubSet(name: name, typeSelections: typeSelections, isActive: false)
        clubSets.append(clubSet)
        saveClubSets()
    }

    func updateClubSet(_ clubSet: ClubSet, name: String, typeSelections: [TypeSelection]) {
        guard let index = clubSets.firstIndex(where: { $0.id == clubSet.id }) else { return }

        clubSets[index].name = name
        clubSets[index].typeSelections = typeSelections
        clubSets[index].dateModified = Date()
        saveClubSets()
    }

    func setActiveClubForType(in clubSet: ClubSet, typeId: UUID, clubId: UUID?) {
        guard let setIndex = clubSets.firstIndex(where: { $0.id == clubSet.id }),
              let typeIndex = clubSets[setIndex].typeSelections.firstIndex(where: { $0.typeId == typeId }) else { return }

        clubSets[setIndex].typeSelections[typeIndex].activeClubId = clubId
        clubSets[setIndex].dateModified = Date()
        saveClubSets()
    }

    func deleteClubSet(_ clubSet: ClubSet) {
        clubSets.removeAll { $0.id == clubSet.id }
        saveClubSets()
        SupabaseSync.shared.deleteClubSet(id: clubSet.id)
    }

    func setActiveClubSet(_ clubSet: ClubSet) {
        for i in 0..<clubSets.count {
            clubSets[i].isActive = false
        }

        if let index = clubSets.firstIndex(where: { $0.id == clubSet.id }) {
            clubSets[index].isActive = true
        }

        saveClubSets()
    }

    var activeClubSet: ClubSet? {
        return clubSets.first { $0.isActive }
    }

    func getTypesInActiveSet() -> [ClubTypeData] {
        guard let activeSet = activeClubSet else { return [] }
        return activeSet.typeSelections.compactMap { selection in
            clubTypes.first { $0.id == selection.typeId }
        }
    }

    func getActiveClubForType(_ typeId: UUID) -> ClubData? {
        guard let activeSet = activeClubSet,
              let clubId = activeSet.getActiveClubId(for: typeId) else { return nil }
        return availableClubs.first { $0.id == clubId }
    }

    /// Returns only the clubs that are active in the current club set
    /// This filters to clubs where the type is in the set AND has an active club selected
    func getClubsInActiveSet() -> [ClubData] {
        guard let activeSet = activeClubSet else { return [] }
        return activeSet.typeSelections.compactMap { selection in
            guard let clubId = selection.activeClubId else { return nil }
            return availableClubs.first { $0.id == clubId }
        }
    }

    /// Returns the club types that are in the active set AND have an active club selected
    /// This is used for club selection UI during rounds
    func getTypesWithActiveClubs() -> [ClubTypeData] {
        guard let activeSet = activeClubSet else { return [] }
        return activeSet.typeSelections.compactMap { selection in
            // Only include types that have an active club selected
            guard selection.activeClubId != nil else { return nil }
            return clubTypes.first { $0.id == selection.typeId }
        }
    }
}

struct HoleDetectionRunState {
    var isRunning: Bool
    var message: String
    var progress: Double
    var error: String?
}

private struct HoleDetectionDiagnostics {
    var tileCount: Int
    var totalGreenPixels: Int
    var totalGreenishPixels: Int
    var totalSwappedChannelExactPixels: Int
    var preMergeBlobCount: Int
    var mergedBlobCount: Int
    var topGreenishColors: [HoleDetectionColorCount]

    var summaryMessage: String {
        "Hole detection ready (\(totalGreenPixels) exact px, \(totalGreenishPixels) greenish px, \(mergedBlobCount) blobs)"
    }
}

private struct HoleDetectionAnalyzeResult {
    var data: CourseHoleDetectionData
    var diagnostics: HoleDetectionDiagnostics
}

private struct HoleDetectionRGB {
    var r: Int
    var g: Int
    var b: Int

    var formatted: String {
        "\(r),\(g),\(b)"
    }
}

private struct HoleDetectionColorCount {
    var color: HoleDetectionRGB
    var count: Int

    var formatted: String {
        "rgb(\(color.formatted))=\(count)"
    }
}

private struct HoleDetectionTileResult {
    var blobs: [HoleDetectionBlob]
    var greenPixelCount: Int
    var greenishPixelCount: Int
    var swappedChannelExactCount: Int
    var greenishColorCounts: [UInt32: Int]
}

private final class HoleDetectionAnalyzer {
    // Exact standard-map green/tee fill from iPhone snapshots.
    private let greenColor = (r: 186, g: 232, b: 153)
    private let sandColor = (r: 245, g: 242, b: 218)
    private let sandTolerance = 10
    private let sandScanRadius = 20
    private let sandWeight = 1.0
    private let areaWeight = 0.6
    private let widthWeight = 1.0

    private let tileDiameterMeters: Double = 2000.0
    private let tileSpacingMeters: Double = 1800.0
    private let tilePixelSize = 1600
    private let duplicateDistanceMeters: Double = 18.0
    private let minimumRawArea = 20
    private let maxPolygonPoints = 24
    private let diagnosticsTopColorLimit = 10
    private let diagnosticsColorCountThreshold = 1000

    func detect(
        courseId: UUID,
        center: CLLocationCoordinate2D,
        coverageRadiusMeters: Double,
        boundingPolygons: [[CLLocationCoordinate2D]]? = nil,
        progress: @escaping (String, Double) -> Void,
        completion: @escaping (Result<HoleDetectionAnalyzeResult, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let tileCenters = self.buildTileCenters(center: center, coverageRadiusMeters: coverageRadiusMeters)
                var blobs: [HoleDetectionBlob] = []
                let totalTiles = max(tileCenters.count, 1)
                var totalGreenPixels = 0
                var totalGreenishPixels = 0
                var totalSwappedChannelExactPixels = 0
                var mergedGreenishColorCounts: [UInt32: Int] = [:]

                for (index, tileCenter) in tileCenters.enumerated() {
                    let progressValue = Double(index) / Double(totalTiles)
                    progress("Scanning map \(index + 1)/\(totalTiles)...", progressValue)

                    let snapshotImage = try self.snapshotStandardMap(center: tileCenter)
                    let tileResult = self.detectBlobs(
                        in: snapshotImage,
                        tileCenter: tileCenter,
                        tileDiameterMeters: self.tileDiameterMeters
                    )
                    blobs.append(contentsOf: tileResult.blobs)
                    totalGreenPixels += tileResult.greenPixelCount
                    totalGreenishPixels += tileResult.greenishPixelCount
                    totalSwappedChannelExactPixels += tileResult.swappedChannelExactCount
                    for (color, count) in tileResult.greenishColorCounts {
                        mergedGreenishColorCounts[color, default: 0] += count
                    }

                    let tileMessage = "Tile \(index + 1)/\(totalTiles): exact \(tileResult.greenPixelCount) px, greenish \(tileResult.greenishPixelCount) px, swapped \(tileResult.swappedChannelExactCount), blobs \(tileResult.blobs.count)"
                    progress(tileMessage, min(progressValue + (0.8 / Double(totalTiles)), 0.94))
                }

                progress("Merging overlaps...", 0.95)
                let mergedBlobs = self.mergeDuplicateBlobs(blobs)

                // Polygon gate: when the OSM relation gave us a course
                // outline, drop any merged blob whose centroid sits
                // outside ALL of the bounding polygons. Multiple polygons
                // = canonical + sibling-relation outlines unioned (e.g.
                // courses with two competing OSM features for the same
                // physical course). When boundingPolygons is nil we fall
                // back to the radius-only behaviour.
                let scopedBlobs: [HoleDetectionBlob] = {
                    guard let polys = boundingPolygons, !polys.isEmpty else { return mergedBlobs }
                    return mergedBlobs.filter { blob in
                        let pt = CLLocationCoordinate2D(latitude: blob.centroidLatitude, longitude: blob.centroidLongitude)
                        return polys.contains { Self.pointInPolygon(pt, polygon: $0) }
                    }
                }()

                let data = CourseHoleDetectionData(
                    courseId: courseId,
                    generatedAt: Date(),
                    blobs: scopedBlobs
                )
                let topGreenishColors = mergedGreenishColorCounts
                    .filter { $0.value >= self.diagnosticsColorCountThreshold }
                    .sorted {
                        if $0.value == $1.value { return $0.key < $1.key }
                        return $0.value > $1.value
                    }
                    .prefix(self.diagnosticsTopColorLimit)
                    .map {
                        HoleDetectionColorCount(
                            color: self.unpackRGB($0.key),
                            count: $0.value
                        )
                    }

                let diagnostics = HoleDetectionDiagnostics(
                    tileCount: tileCenters.count,
                    totalGreenPixels: totalGreenPixels,
                    totalGreenishPixels: totalGreenishPixels,
                    totalSwappedChannelExactPixels: totalSwappedChannelExactPixels,
                    preMergeBlobCount: blobs.count,
                    mergedBlobCount: scopedBlobs.count,
                    topGreenishColors: topGreenishColors
                )

                progress(diagnostics.summaryMessage, 1.0)
                completion(.success(HoleDetectionAnalyzeResult(
                    data: data,
                    diagnostics: diagnostics
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func buildTileCenters(center: CLLocationCoordinate2D, coverageRadiusMeters: Double) -> [CLLocationCoordinate2D] {
        let tileRadius = tileDiameterMeters / 2
        let neededSteps = Int(ceil(max(0, coverageRadiusMeters - tileRadius) / tileSpacingMeters))
        let stepCount = max(1, min(2, neededSteps))

        var centers: [CLLocationCoordinate2D] = []
        for y in (-stepCount)...stepCount {
            for x in (-stepCount)...stepCount {
                let northMeters = Double(y) * tileSpacingMeters
                let eastMeters = Double(x) * tileSpacingMeters
                centers.append(offsetCoordinate(from: center, northMeters: northMeters, eastMeters: eastMeters))
            }
        }
        return centers
    }

    private func snapshotStandardMap(center: CLLocationCoordinate2D) throws -> CGImage {
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: center,
            latitudinalMeters: tileDiameterMeters,
            longitudinalMeters: tileDiameterMeters
        )
        options.size = CGSize(width: tilePixelSize, height: tilePixelSize)
        options.mapType = .standard
        options.showsBuildings = false
        options.pointOfInterestFilter = .excludingAll
        // Force light mode and 1x scale so the green fill color (186,232,153) matches
        // regardless of the device's appearance setting or display scale.
        options.traitCollection = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: .light),
            UITraitCollection(displayScale: 1.0)
        ])

        let semaphore = DispatchSemaphore(value: 0)
        var capturedImage: CGImage?
        var capturedError: Error?

        // MKMapSnapshotter must be created and started on the main thread.
        // The completion handler is also delivered on main, which is fine
        // since we only block the background thread with the semaphore.
        DispatchQueue.main.async {
            let snapshotter = MKMapSnapshotter(options: options)
            snapshotter.start { snapshot, error in
                if let error = error {
                    capturedError = error
                } else {
                    capturedImage = snapshot?.image.cgImage
                }
                semaphore.signal()
            }
        }

        if semaphore.wait(timeout: .now() + 30) == .timedOut {
            throw NSError(
                domain: "HoleDetectionAnalyzer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Map snapshot timed out"]
            )
        }

        if let error = capturedError {
            throw error
        }

        guard let image = capturedImage else {
            throw NSError(
                domain: "HoleDetectionAnalyzer",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "No map snapshot image returned"]
            )
        }

        return image
    }

    private func detectBlobs(
        in image: CGImage,
        tileCenter: CLLocationCoordinate2D,
        tileDiameterMeters: Double
    ) -> HoleDetectionTileResult {
        let width = image.width
        let height = image.height
        let pixelCount = width * height

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixelData = [UInt8](repeating: 0, count: pixelCount * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return HoleDetectionTileResult(
                blobs: [],
                greenPixelCount: 0,
                greenishPixelCount: 0,
                swappedChannelExactCount: 0,
                greenishColorCounts: [:]
            )
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var isGreen = [Bool](repeating: false, count: pixelCount)
        var greenPixelCount = 0
        var greenishPixelCount = 0
        var swappedChannelExactCount = 0
        var greenishColorCounts: [UInt32: Int] = [:]
        for idx in 0..<pixelCount {
            let offset = idx * 4
            let r = Int(pixelData[offset])
            let g = Int(pixelData[offset + 1])
            let b = Int(pixelData[offset + 2])
            let isGreenPixel = (r == greenColor.r && g == greenColor.g && b == greenColor.b)
            isGreen[idx] = isGreenPixel
            if isGreenPixel {
                greenPixelCount += 1
            }
            if b == greenColor.r && g == greenColor.g && r == greenColor.b {
                swappedChannelExactCount += 1
            }
            if g >= 90 && g > r + 8 && g > b + 8 {
                greenishPixelCount += 1
                let key = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
                greenishColorCounts[key, default: 0] += 1
            }
        }

        var visited = [Bool](repeating: false, count: pixelCount)
        let metersPerPixel = tileDiameterMeters / Double(width)
        var detected: [HoleDetectionBlob] = []

        for start in 0..<pixelCount {
            if !isGreen[start] || visited[start] { continue }

            var queue: [Int] = [start]
            visited[start] = true
            var queueIndex = 0

            var area = 0
            var sumX = 0
            var sumY = 0
            var minX = Int.max
            var maxX = Int.min
            var minY = Int.max
            var maxY = Int.min
            var boundaryPoints: [(x: Int, y: Int)] = []

            while queueIndex < queue.count {
                let current = queue[queueIndex]
                queueIndex += 1

                let x = current % width
                let y = current / width

                area += 1
                sumX += x
                sumY += y
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)

                var isBoundaryPixel = false
                let neighbors = [
                    (x: x + 1, y: y),
                    (x: x - 1, y: y),
                    (x: x, y: y + 1),
                    (x: x, y: y - 1)
                ]

                for n in neighbors {
                    guard n.x >= 0, n.x < width, n.y >= 0, n.y < height else {
                        isBoundaryPixel = true
                        continue
                    }

                    let nIdx = n.y * width + n.x
                    if !isGreen[nIdx] {
                        isBoundaryPixel = true
                        continue
                    }

                    if !visited[nIdx] {
                        visited[nIdx] = true
                        queue.append(nIdx)
                    }
                }

                if isBoundaryPixel {
                    boundaryPoints.append((x: x, y: y))
                }
            }

            if area < minimumRawArea { continue }

            let blobWidth = max(1, maxX - minX + 1)
            let blobHeight = max(1, maxY - minY + 1)
            let minWidth = Double(min(blobWidth, blobHeight))
            let maxWidth = Double(max(blobWidth, blobHeight))
            let elongation = maxWidth / max(minWidth, 1.0)
            let centroidX = Double(sumX) / Double(area)
            let centroidY = Double(sumY) / Double(area)

            // Sand-surround percentage replaces the old "raw count of sand
            // pixels in bounding-box-extended-by-radius" metric. The new
            // metric is: cast 72 rays from the centroid, walk past the
            // blob's own green pixels, then walk 10 yd outward; record the
            // fraction of rays that hit any sand pixel within that window.
            // Rewards greens RINGED by bunkers (the diagnostic geometry of
            // a real green) without rewarding a single huge bunker on one
            // side. Mirrors the algorithm proven out in HoleDetect.
            let sandSurroundPct = computeSandSurroundFraction(
                centroidX: centroidX,
                centroidY: centroidY,
                isGreen: isGreen,
                pixelData: pixelData,
                width: width,
                height: height,
                metersPerPixel: metersPerPixel
            )

            let greenness = calculateGreennessScore(
                area: area,
                minWidth: minWidth,
                elongation: elongation,
                sandSurroundPct: sandSurroundPct
            )

            let hull = convexHull(points: boundaryPoints)
            let reducedHull = reducePoints(hull, maxPoints: maxPolygonPoints)
            let polygonPoints: [MapPoint]
            if reducedHull.count >= 3 {
                polygonPoints = reducedHull.map {
                    MapPoint(pixelToCoordinate(
                        x: Double($0.x),
                        y: Double($0.y),
                        tileCenter: tileCenter,
                        imageWidth: Double(width),
                        imageHeight: Double(height),
                        metersPerPixel: metersPerPixel
                    ))
                }
            } else {
                // Fall back to a small box around centroid if hull is too small.
                let halfSize = 2.0
                let fallbackPixels = [
                    (centroidX - halfSize, centroidY - halfSize),
                    (centroidX + halfSize, centroidY - halfSize),
                    (centroidX + halfSize, centroidY + halfSize),
                    (centroidX - halfSize, centroidY + halfSize)
                ]
                polygonPoints = fallbackPixels.map {
                    MapPoint(pixelToCoordinate(
                        x: $0.0,
                        y: $0.1,
                        tileCenter: tileCenter,
                        imageWidth: Double(width),
                        imageHeight: Double(height),
                        metersPerPixel: metersPerPixel
                    ))
                }
            }

            let centroidCoordinate = pixelToCoordinate(
                x: centroidX,
                y: centroidY,
                tileCenter: tileCenter,
                imageWidth: Double(width),
                imageHeight: Double(height),
                metersPerPixel: metersPerPixel
            )

            detected.append(HoleDetectionBlob(
                area: area,
                minWidth: minWidth,
                elongation: elongation,
                greennessScore: greenness,
                centroidLatitude: centroidCoordinate.latitude,
                centroidLongitude: centroidCoordinate.longitude,
                polygon: polygonPoints
            ))
        }

        return HoleDetectionTileResult(
            blobs: detected,
            greenPixelCount: greenPixelCount,
            greenishPixelCount: greenishPixelCount,
            swappedChannelExactCount: swappedChannelExactCount,
            greenishColorCounts: greenishColorCounts
        )
    }

    private func unpackRGB(_ key: UInt32) -> HoleDetectionRGB {
        HoleDetectionRGB(
            r: Int((key >> 16) & 0xFF),
            g: Int((key >> 8) & 0xFF),
            b: Int(key & 0xFF)
        )
    }

    /// Sand-surround percentage for a single blob — the angular-coverage
    /// metric proven out in HoleDetect. Casts `sandSurroundRays` rays from
    /// the centroid (every 5° by default), walks past the blob's own green
    /// pixels (using the precomputed `isGreen` mask — no color-matching
    /// needed), then walks `sandSurroundDistanceYards` outward; records
    /// the fraction of rays that hit any sand pixel within that window.
    /// Returns a value in [0, 100] (1-decimal).
    private func computeSandSurroundFraction(
        centroidX: Double,
        centroidY: Double,
        isGreen: [Bool],
        pixelData: [UInt8],
        width: Int,
        height: Int,
        metersPerPixel: Double
    ) -> Double {
        let rayCount = 72
        let distanceYards = 10.0
        let yardsPerMeter = 1.09361
        let metersPerYard = 1.0 / yardsPerMeter
        let outwardSteps = max(1, Int(((distanceYards * metersPerYard) / metersPerPixel).rounded()))
        let maxBlobSkip = 200

        @inline(__always)
        func pxIsGreen(_ x: Int, _ y: Int) -> Bool {
            if x < 0 || x >= width || y < 0 || y >= height { return false }
            return isGreen[y * width + x]
        }

        @inline(__always)
        func pxIsSand(_ x: Int, _ y: Int) -> Bool {
            if x < 0 || x >= width || y < 0 || y >= height { return false }
            let o = (y * width + x) * 4
            let r = Int(pixelData[o]), g = Int(pixelData[o + 1]), b = Int(pixelData[o + 2])
            return abs(r - sandColor.r) <= sandTolerance
                && abs(g - sandColor.g) <= sandTolerance
                && abs(b - sandColor.b) <= sandTolerance
        }

        var hits = 0
        for i in 0..<rayCount {
            let angle = Double(i) / Double(rayCount) * 2.0 * .pi
            let dx = cos(angle)
            let dy = sin(angle)
            // Walk past in-blob green pixels first (radial exit through perimeter)
            var step = 0
            while step < maxBlobSkip {
                let x = Int((centroidX + dx * Double(step)).rounded())
                let y = Int((centroidY + dy * Double(step)).rounded())
                if !pxIsGreen(x, y) { break }
                step += 1
            }
            // Then walk outward checking for sand
            var rayHit = false
            for k in 0...outwardSteps {
                let x = Int((centroidX + dx * Double(step + k)).rounded())
                let y = Int((centroidY + dy * Double(step + k)).rounded())
                if pxIsSand(x, y) { rayHit = true; break }
            }
            if rayHit { hits += 1 }
        }
        let pct = Double(hits) / Double(rayCount) * 1000.0
        return (pct.rounded()) / 10.0
    }

    /// Greenness score: shape-only base, then multiplied by sand-surround %
    /// when > 1 (no penalty for unbunkered greens). Mirrors the formula in
    /// HoleDetect's `calculateGreennessScore`.
    private func calculateGreennessScore(area: Int, minWidth: Double, elongation: Double, sandSurroundPct: Double) -> Int {
        let areaContrib = Double(area) * areaWeight
        let widthContrib = minWidth * widthWeight
        let elongationPenalty = max(elongation * elongation, 1.0e-6)
        let base = (areaContrib + widthContrib) / elongationPenalty
        let multiplier = sandSurroundPct > 1.0 ? sandSurroundPct : 1.0
        return Int((base * multiplier).rounded())
    }

    /// Standard ray-casting point-in-polygon. Used by the bounding-polygon
    /// gate to drop blobs detected on neighboring courses. Same algorithm
    /// as `HoleDetectionBlob.contains` — duplicated as a static here to
    /// avoid leaking analyzer concerns into the model layer.
    static func pointInPolygon(_ pt: CLLocationCoordinate2D, polygon: [CLLocationCoordinate2D]) -> Bool {
        guard polygon.count >= 3 else { return false }
        let x = pt.longitude, y = pt.latitude
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let xi = polygon[i].longitude, yi = polygon[i].latitude
            let xj = polygon[j].longitude, yj = polygon[j].latitude
            if (yi > y) != (yj > y) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    private func mergeDuplicateBlobs(_ blobs: [HoleDetectionBlob]) -> [HoleDetectionBlob] {
        let sorted = blobs.sorted {
            if $0.greennessScore == $1.greennessScore {
                return $0.area > $1.area
            }
            return $0.greennessScore > $1.greennessScore
        }

        var merged: [HoleDetectionBlob] = []
        for blob in sorted {
            if let matchIndex = merged.firstIndex(where: {
                distanceMeters(
                    CLLocationCoordinate2D(latitude: $0.centroidLatitude, longitude: $0.centroidLongitude),
                    CLLocationCoordinate2D(latitude: blob.centroidLatitude, longitude: blob.centroidLongitude)
                ) < duplicateDistanceMeters
            }) {
                let existing = merged[matchIndex]
                if blob.greennessScore > existing.greennessScore ||
                    (blob.greennessScore == existing.greennessScore && blob.area > existing.area) {
                    merged[matchIndex] = blob
                }
            } else {
                merged.append(blob)
            }
        }
        return merged
    }

    private func distanceMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        let aLoc = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let bLoc = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return aLoc.distance(from: bLoc)
    }

    private func pixelToCoordinate(
        x: Double,
        y: Double,
        tileCenter: CLLocationCoordinate2D,
        imageWidth: Double,
        imageHeight: Double,
        metersPerPixel: Double
    ) -> CLLocationCoordinate2D {
        let pixelOffsetX = x - (imageWidth / 2.0)
        let pixelOffsetY = y - (imageHeight / 2.0)

        let metersEast = pixelOffsetX * metersPerPixel
        let metersNorth = -pixelOffsetY * metersPerPixel

        let metersPerDegreeLat = 111000.0
        let metersPerDegreeLon = 111000.0 * cos(tileCenter.latitude * .pi / 180.0)

        return CLLocationCoordinate2D(
            latitude: tileCenter.latitude + (metersNorth / metersPerDegreeLat),
            longitude: tileCenter.longitude + (metersEast / metersPerDegreeLon)
        )
    }

    private func offsetCoordinate(from coordinate: CLLocationCoordinate2D, northMeters: Double, eastMeters: Double) -> CLLocationCoordinate2D {
        let metersPerDegreeLat = 111000.0
        let metersPerDegreeLon = 111000.0 * cos(coordinate.latitude * .pi / 180.0)
        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + (northMeters / metersPerDegreeLat),
            longitude: coordinate.longitude + (eastMeters / metersPerDegreeLon)
        )
    }

    private func convexHull(points: [(x: Int, y: Int)]) -> [(x: Int, y: Int)] {
        guard points.count >= 3 else { return points }

        let sorted = points.sorted { lhs, rhs in
            lhs.x < rhs.x || (lhs.x == rhs.x && lhs.y < rhs.y)
        }

        func cross(_ a: (x: Int, y: Int), _ b: (x: Int, y: Int), _ c: (x: Int, y: Int)) -> Int {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }

        var lower: [(x: Int, y: Int)] = []
        for point in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                _ = lower.popLast()
            }
            lower.append(point)
        }

        var upper: [(x: Int, y: Int)] = []
        for point in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                _ = upper.popLast()
            }
            upper.append(point)
        }

        _ = lower.popLast()
        _ = upper.popLast()
        return lower + upper
    }

    private func reducePoints(_ points: [(x: Int, y: Int)], maxPoints: Int) -> [(x: Int, y: Int)] {
        guard points.count > maxPoints, maxPoints > 2 else { return points }
        var reduced: [(x: Int, y: Int)] = []
        let step = Double(points.count) / Double(maxPoints)
        for i in 0..<maxPoints {
            let index = min(points.count - 1, Int((Double(i) * step).rounded(.down)))
            reduced.append(points[index])
        }
        return reduced
    }
}
