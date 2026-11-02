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
    var pendingTeePickerResolution: RoundResolver.Resolution?

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
    var context: ModelContext? { sharedContext }
    /// Public read-only accessor so `RealtimeSync` can apply postgres-changes
    /// echoes into the SAME context our local mutations use.
    var modelContext: ModelContext? { sharedContext }

    let holeDetectionFileName = "holeDetectionData.json"
    private let playerStatsFileName = "playerStats.json"
    let holeFilterSettingsKey = "holeFilterSettings"
    let holeDetectionAnalyzer = HoleDetectionAnalyzer()
    let holeDetectionTestCenter = CLLocationCoordinate2D(
        latitude: 30.285357365597697,
        longitude: -81.74623642434663
    )
    let watchHoleDetectionQueueKey = "watchHoleDetectionQueue"
    /// Covers a run the user backgrounds midway, so it can finish.
    var holeDetectionBackgroundTasks: [UUID: UIBackgroundTaskIdentifier] = [:]

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
    var currentUserUUID: UUID? {
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
