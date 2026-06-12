import Foundation
import Supabase
import SwiftData

/// Subscribes to Supabase Realtime postgres-change streams for the user's
/// rounds + active round's children (strokes, targets, round_holes), plus
/// the slower-moving relational state (courses, holes, club_types, clubs,
/// club_sets). When changes flow in, they're applied to the local SwiftData
/// container. The result: a stroke recorded on the watch shows up on the
/// phone within ~200ms (and vice versa), without WatchConnectivity touching
/// the round/stroke path.
///
/// Single channel per user (`user:<uid>`); within it, separate subscriptions
/// per table. Channel lifecycle is tied to sign-in/sign-out — we (re-)subscribe
/// when an auth session is present and tear down on sign-out.
final class RealtimeSync {
    static let shared = RealtimeSync()

    private let supabase = SupabaseManager.shared

    private var modelContainer: ModelContainer?
    /// Critical: returns the SAME `ModelContext` instance used by the
    /// platform DataStore so mutations from Realtime echoes and from
    /// local user actions land in one coherent view of the store.
    /// Separate contexts produced a 21s stale-read bug we hit before this
    /// fix — see commit history.
    private var context: ModelContext? {
        #if os(watchOS)
        return WatchDataStore.shared.modelContext
        #else
        return DataStore.shared.modelContext
        #endif
    }

    private var subscriptions: [Task<Void, Never>] = []
    private var activeChannel: RealtimeChannelV2?
    private var activeUserId: String?
    /// Long-lived task that drives the channel's persistent subscribe loop
    /// (retry/backoff/reconnect via RealtimeReconnect). Cancelled on
    /// `teardown()` to stop the loop and unsubscribe the channel.
    private var subscribeLoopTask: Task<Void, Never>?

    private init() {}

    // MARK: - Lifecycle

    /// Wired at app startup after the ModelContainer is built. Realtime won't
    /// do anything until `start(forUserId:)` is called by the auth listener.
    func configure(container: ModelContainer) {
        self.modelContainer = container
    }

    /// Start (or restart) subscriptions for a signed-in user. Idempotent — if
    /// already running for this user, no-ops; if running for a different user,
    /// tears the old subscriptions down first.
    ///
    /// **Lifecycle model:** call from the active round view's `.onAppear` and
    /// `stop()` from `.onDisappear`. Keeping the WebSocket open 24/7 burns
    /// idle bandwidth (~8MB/month per device just heartbeats) and watch
    /// battery for no benefit when no round is in flight. Cross-device sync
    /// only matters during active play.
    func start(forUserId userId: String) {
        if activeUserId == userId, !subscriptions.isEmpty { return }
        Task { await self.restart(forUserId: userId) }
    }

    /// Tear down all subscriptions and unsubscribe the channel.
    func stop() {
        Task { await self.teardown() }
    }

    /// Pull recent rounds + their `round_holes` and `strokes` from Supabase
    /// and upsert into the local SwiftData store via the same apply* paths
    /// Realtime uses. Required because postgres-changes are live-only —
    /// nothing replays events missed while the WebSocket was down or the app
    /// was backgrounded. Without this the iPhone keeps a stale partial view
    /// of any round the watch played while the iPhone wasn't actively
    /// listening.
    ///
    /// Idempotent. Safe to call repeatedly. Hook points:
    /// - sign-in (AuthManager)
    /// - app foreground (scenePhase == .active)
    /// - every successful Realtime re-subscribe (RealtimeReconnect)
    /// Same window the iOS DataStore uses for "current round" — keep these
    /// in sync. Hardcoded here (rather than referencing DataStore directly)
    /// because RealtimeSync compiles into both iOS and watchOS targets and
    /// WatchDataStore doesn't expose the same constant.
    private static let reconcileWindowSeconds: TimeInterval = 8 * 60 * 60

    func reconcileRoundsWithSupabase() async {
        // Prefer activeUserId (set when Realtime is running); fall back to the
        // platform auth source so reconcile can fire from app-foreground / sign-in
        // hooks even if start() hasn't been called yet on this launch.
        let resolvedUserId: String? = {
            if let uid = activeUserId { return uid }
            #if os(watchOS)
            return WatchAuthSession.shared.currentUserId
            #else
            return AuthManager.shared.currentUserId
            #endif
        }()
        guard let userId = resolvedUserId else { return }
        let cutoff = Date().addingTimeInterval(-Self.reconcileWindowSeconds)
        let cutoffISO = Self.isoFormatter.string(from: cutoff)
        do {
            // Pull rounds first so child upserts can link via parent.
            let roundRows: [AnyJSON] = try await supabase
                .from("rounds")
                .select()
                .eq("user_id", value: userId)
                .gte("date", value: cutoffISO)
                .execute()
                .value

            let roundIds: [String] = roundRows.compactMap { $0.objectValue?["id"]?.stringValue }
            let courseIds: [String] = Array(Set(
                roundRows.compactMap { $0.objectValue?["course_id"]?.stringValue }
            ))

            // Pull child rows BEFORE touching the context. Networking stays
            // off-main; ModelContext mutation is wrapped in MainActor.run
            // below because the context was created on the main queue and
            // SwiftData fatal-errors if it's mutated from a Task.
            // Courses (and their holes) are included: a round recovered via
            // reconcile is unrenderable without its course row — the live
            // courses INSERT is easy to miss since it fires once, at
            // resolve time, often while this device is backgrounded.
            let holeRows: [AnyJSON]
            let strokeRows: [AnyJSON]
            let courseRows: [AnyJSON]
            let courseHoleRows: [AnyJSON]
            if roundIds.isEmpty {
                holeRows = []; strokeRows = []; courseRows = []; courseHoleRows = []
            } else {
                holeRows = (try? await supabase
                    .from("round_holes")
                    .select()
                    .in("round_id", values: roundIds)
                    .execute()
                    .value) ?? []
                strokeRows = (try? await supabase
                    .from("strokes")
                    .select()
                    .in("round_id", values: roundIds)
                    .execute()
                    .value) ?? []
                courseRows = (try? await supabase
                    .from("courses")
                    .select()
                    .in("id", values: courseIds)
                    .execute()
                    .value) ?? []
                courseHoleRows = (try? await supabase
                    .from("holes")
                    .select()
                    .in("course_id", values: courseIds)
                    .execute()
                    .value) ?? []
            }

            await MainActor.run {
                guard let context = context else { return }
                // Courses before rounds/holes so parent linkage resolves.
                for row in courseRows {
                    guard let dict = row.objectValue,
                          let idStr = dict["id"]?.stringValue,
                          let id = UUID(uuidString: idStr) else { continue }
                    applyCourse(context: context, kind: .update, id: id, record: dict)
                }
                for row in courseHoleRows {
                    guard let dict = row.objectValue,
                          let idStr = dict["id"]?.stringValue,
                          let id = UUID(uuidString: idStr) else { continue }
                    applyHole(context: context, kind: .update, id: id, record: dict, fromRoundHoles: false)
                }
                for row in roundRows {
                    guard let dict = row.objectValue,
                          let idStr = dict["id"]?.stringValue,
                          let id = UUID(uuidString: idStr) else { continue }
                    applyRound(context: context, kind: .update, id: id, record: dict)
                }
                for row in holeRows {
                    guard let dict = row.objectValue,
                          let idStr = dict["id"]?.stringValue,
                          let id = UUID(uuidString: idStr) else { continue }
                    applyHole(context: context, kind: .update, id: id, record: dict, fromRoundHoles: true)
                }
                for row in strokeRows {
                    guard let dict = row.objectValue,
                          let idStr = dict["id"]?.stringValue,
                          let id = UUID(uuidString: idStr) else { continue }
                    applyStroke(context: context, kind: .update, id: id, record: dict)
                }
                try? context.save()
                ClientEventLogger.log("realtime.reconcile.ok", detail: [
                    "rounds": .integer(roundRows.count)
                ])

                // Push the platform store to refresh @Published arrays so the UI
                // observes the new state — same pattern as `apply(...)`'s tail.
                #if os(watchOS)
                WatchDataStore.shared.refreshCurrentRound()
                WatchDataStore.shared.objectWillChange.send()
                #else
                DataStore.shared.loadRounds()
                DataStore.shared.loadCourses()
                DataStore.shared.objectWillChange.send()
                #endif
            }
        } catch {
            ClientEventLogger.log("realtime.reconcile.failed", detail: [
                "error": .string("\(error)")
            ])
        }
    }

    private func restart(forUserId userId: String) async {
        await teardown()
        activeUserId = userId

        let channel = supabase.realtime.channel("user:\(userId)")
        activeChannel = channel

        // user-keyed tables: filter server-side
        wireUserKeyedTable(channel, "rounds", userId: userId)
        // courses is shared across all users (migration 00026); RLS enforces
        // read-all-authenticated. No user filter — every client sees every
        // INSERT/UPDATE/DELETE so newly-registered shared courses stream in
        // live to every device.
        wireUnfilteredTable(channel, "courses")
        wireUserKeyedTable(channel, "club_types", userId: userId)
        wireUserKeyedTable(channel, "clubs", userId: userId)
        wireUserKeyedTable(channel, "club_sets", userId: userId)

        // round-keyed children: no user_id column on these, but RLS already
        // restricts visible rows to the signed-in user's rounds. Subscribe
        // unfiltered and apply locally.
        wireUnfilteredTable(channel, "strokes")
        wireUnfilteredTable(channel, "targets")
        wireUnfilteredTable(channel, "round_holes")
        wireUnfilteredTable(channel, "holes")

        // Persistent subscribe with retry/backoff via RealtimeReconnect.
        // Cancelled by teardown(); loops internally on socket loss / OS
        // backgrounding / network changes until then. The `onSubscribed`
        // callback runs after every successful (re-)subscribe — catches up
        // events missed during gaps, since postgres-changes are live-only.
        subscribeLoopTask = Task { [weak self] in
            await channel.subscribePersistently(label: "realtimeSync") {
                await self?.reconcileRoundsWithSupabase()
            }
        }
    }

    private func teardown() async {
        for task in subscriptions { task.cancel() }
        subscriptions.removeAll()
        subscribeLoopTask?.cancel()
        subscribeLoopTask = nil
        if let channel = activeChannel {
            await channel.unsubscribe()
        }
        activeChannel = nil
        activeUserId = nil
    }

    // MARK: - Subscription wiring

    private func wireUserKeyedTable(_ channel: RealtimeChannelV2, _ table: String, userId: String) {
        let pgFilter: RealtimePostgresFilter = .eq("user_id", value: userId)
        let inserts = channel.postgresChange(InsertAction.self, table: table, filter: pgFilter)
        let updates = channel.postgresChange(UpdateAction.self, table: table, filter: pgFilter)
        let deletes = channel.postgresChange(DeleteAction.self, table: table, filter: pgFilter)
        subscriptions.append(Task { [weak self] in
            for await action in inserts { self?.apply(table: table, kind: .insert, record: action.record) }
        })
        subscriptions.append(Task { [weak self] in
            for await action in updates { self?.apply(table: table, kind: .update, record: action.record) }
        })
        subscriptions.append(Task { [weak self] in
            for await action in deletes { self?.apply(table: table, kind: .delete, record: action.oldRecord) }
        })
    }

    private func wireUnfilteredTable(_ channel: RealtimeChannelV2, _ table: String) {
        let inserts = channel.postgresChange(InsertAction.self, table: table)
        let updates = channel.postgresChange(UpdateAction.self, table: table)
        let deletes = channel.postgresChange(DeleteAction.self, table: table)
        subscriptions.append(Task { [weak self] in
            for await action in inserts { self?.apply(table: table, kind: .insert, record: action.record) }
        })
        subscriptions.append(Task { [weak self] in
            for await action in updates { self?.apply(table: table, kind: .update, record: action.record) }
        })
        subscriptions.append(Task { [weak self] in
            for await action in deletes { self?.apply(table: table, kind: .delete, record: action.oldRecord) }
        })
    }

    // MARK: - Apply changes to SwiftData

    private enum ChangeKind { case insert, update, delete }

    private func apply(table: String, kind: ChangeKind, record: [String: AnyJSON]) {
        guard let context = context else { return }
        guard let idString = record["id"]?.stringValue, let id = UUID(uuidString: idString) else { return }

        switch table {
        case "rounds":   applyRound(context: context, kind: kind, id: id, record: record)
        case "courses":  applyCourse(context: context, kind: kind, id: id, record: record)
        case "holes":    applyHole(context: context, kind: kind, id: id, record: record, fromRoundHoles: false)
        case "round_holes": applyHole(context: context, kind: kind, id: id, record: record, fromRoundHoles: true)
        case "strokes":  applyStroke(context: context, kind: kind, id: id, record: record)
        case "targets":  applyTarget(context: context, kind: kind, id: id, record: record)
        case "club_types":  applyClubType(context: context, kind: kind, id: id, record: record)
        case "clubs":       applyClub(context: context, kind: kind, id: id, record: record)
        case "club_sets":   applyClubSet(context: context, kind: kind, id: id, record: record)
        default: break
        }
        try? context.save()
        ClientEventLogger.log("realtime.apply", detail: [
            "table": .string(table),
            "kind": .string("\(kind)")
        ])
        // Notify the platform store so views observing it (which use computed
        // properties like currentRound that re-fetch on each access) actually
        // re-render when these mutations land. Without this, the iPhone can
        // change holes / record strokes and the watch's view won't update
        // until the user navigates the watch UI manually.
        let isClubsRelated = (table == "clubs" || table == "club_types" || table == "club_sets")
        let isRoundsRelated = (table == "rounds" || table == "round_holes" || table == "holes")
        Task { @MainActor in
            #if os(watchOS)
            if isClubsRelated { WatchDataStore.shared.refreshClubsCache() }
            // Re-evaluate "current round" when an inbound Round / Hole event
            // lands. Without this, a phone-started round wouldn't show as
            // current on the watch even though its row IS in our SwiftData.
            if isRoundsRelated { WatchDataStore.shared.refreshCurrentRound() }
            WatchDataStore.shared.objectWillChange.send()
            #else
            // iPhone: refresh the @Published `rounds`/`courses` arrays when
            // those tables change. The arrays are loaded once via SwiftData
            // fetch at launch and are NOT live-bound to the store, so
            // applyRound's SwiftData writes are invisible to view code
            // (RoundsHistoryView reads `store.rounds`) without an explicit
            // refresh. Same gap caused watch-started rounds to not appear in
            // the iPhone rounds list.
            if isRoundsRelated { DataStore.shared.loadRounds() }
            if table == "courses" { DataStore.shared.loadCourses() }
            DataStore.shared.objectWillChange.send()
            #endif
        }
    }

    private func applyRound(context: ModelContext, kind: ChangeKind, id: UUID, record: [String: AnyJSON]) {
        let descriptor = FetchDescriptor<Round>(predicate: #Predicate { $0.id == id })
        let existing = (try? context.fetch(descriptor))?.first

        if kind == .delete {
            if let existing = existing { context.delete(existing) }
            return
        }
        let courseId = record["course_id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? UUID()
        let courseName = record["course_name"]?.stringValue ?? ""
        let date = record["date"]?.stringValue.flatMap(Self.parseISODate) ?? Date()
        let currentHoleIndex = record["current_hole_index"]?.intValue ?? 0
        let completed = (record["completed_holes"]?.arrayValue?.compactMap { $0.intValue }) ?? []

        let selectedTeeId = record["selected_tee_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let endedAt = record["ended_at"]?.stringValue.flatMap(Self.parseISODate)
        let lastActivityAt = record["last_activity_at"]?.stringValue.flatMap(Self.parseISODate)
        if let existing = existing {
            existing.courseId = courseId
            existing.courseName = courseName
            existing.date = date
            existing.currentHoleIndex = currentHoleIndex
            existing.completedHolesArray = completed
            existing.holeDetectionEnabled = record["hole_detection_enabled"]?.boolValue
            existing.locationTestModeEnabled = record["location_test_mode_enabled"]?.boolValue
            existing.selectedTeeId = selectedTeeId
            existing.endedAt = endedAt
            existing.lastActivityAt = lastActivityAt
        } else {
            let r = Round(
                id: id,
                courseId: courseId,
                courseName: courseName,
                holes: [],
                date: date,
                selectedTeeId: selectedTeeId
            )
            r.currentHoleIndex = currentHoleIndex
            r.completedHolesArray = completed
            r.holeDetectionEnabled = record["hole_detection_enabled"]?.boolValue
            r.locationTestModeEnabled = record["location_test_mode_enabled"]?.boolValue
            r.endedAt = endedAt
            r.lastActivityAt = lastActivityAt
            context.insert(r)
            adoptOrphans(context: context, round: r)
        }
    }

    /// Re-attach any Hole / Stroke rows that arrived before this Round and got
    /// inserted with `round == nil`. They carry `roundIdRef` so we can find
    /// them after the parent finally lands. Without this, out-of-order
    /// Realtime delivery silently drops children from the round's
    /// relationships and never repairs.
    private func adoptOrphans(context: ModelContext, round: Round) {
        let id = round.id
        let holeDescriptor = FetchDescriptor<Hole>(predicate: #Predicate { $0.round == nil && $0.roundIdRef == id })
        if let orphans = try? context.fetch(holeDescriptor) {
            for h in orphans { round.holes.append(h) }
        }
        let strokeDescriptor = FetchDescriptor<Stroke>(predicate: #Predicate { $0.round == nil && $0.roundIdRef == id })
        if let orphans = try? context.fetch(strokeDescriptor) {
            for s in orphans { round.strokes.append(s) }
        }
    }

    private func applyCourse(context: ModelContext, kind: ChangeKind, id: UUID, record: [String: AnyJSON]) {
        let descriptor = FetchDescriptor<Course>(predicate: #Predicate { $0.id == id })
        let existing = (try? context.fetch(descriptor))?.first
        if kind == .delete {
            if let existing = existing { context.delete(existing) }
            return
        }
        let name = record["name"]?.stringValue ?? ""
        let rating = record["rating"]?.doubleValue
        let slope = record["slope"]?.intValue
        let city = record["city"]?.stringValue
        let externalCourseId = record["external_course_id"]?.stringValue
        let centerLat = record["center_lat"]?.doubleValue
        let centerLon = record["center_lon"]?.doubleValue
        let osmId = record["osm_id"]?.intValue.map(Int64.init)
        if let existing = existing {
            existing.name = name
            existing.rating = rating
            existing.slope = slope
            existing.city = city
            existing.externalCourseId = externalCourseId
            existing.centerLat = centerLat
            existing.centerLon = centerLon
            existing.osmId = osmId
        } else {
            context.insert(Course(
                id: id,
                name: name,
                holes: [],
                rating: rating,
                slope: slope,
                city: city,
                centerLat: centerLat,
                centerLon: centerLon,
                osmId: osmId,
                externalCourseId: externalCourseId
            ))
        }
    }

    private func applyHole(context: ModelContext, kind: ChangeKind, id: UUID, record: [String: AnyJSON], fromRoundHoles: Bool) {
        let descriptor = FetchDescriptor<Hole>(predicate: #Predicate { $0.id == id })
        let existing = (try? context.fetch(descriptor))?.first
        if kind == .delete {
            guard let existing else { return }
            if fromRoundHoles, existing.course != nil {
                // Rounds share the course's Hole instances. A deleted round
                // cascades its round_holes rows server-side — that must
                // detach the hole from the round, never delete the course's
                // hole out from under it.
                existing.round = nil
                existing.roundIdRef = nil
            } else {
                context.delete(existing)
            }
            return
        }
        let number = record["number"]?.intValue ?? 0
        let lat = record["latitude"]?.doubleValue
        let lon = record["longitude"]?.doubleValue
        let par = record["par"]?.intValue
        let teeId = record["tee_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let roundId = record["round_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        if let existing = existing {
            existing.number = number; existing.latitude = lat; existing.longitude = lon; existing.par = par
            existing.teeId = teeId
            // Update parent ref + repair link if the row landed orphaned earlier.
            if let roundId = roundId {
                existing.roundIdRef = roundId
                if existing.round == nil {
                    let rd = FetchDescriptor<Round>(predicate: #Predicate { $0.id == roundId })
                    if let round = (try? context.fetch(rd))?.first {
                        round.holes.append(existing)
                    }
                }
            }
        } else {
            let h = Hole(id: id, number: number)
            h.latitude = lat; h.longitude = lon; h.par = par; h.teeId = teeId
            h.roundIdRef = roundId
            context.insert(h)
            // Best-effort link to its round via round_id, if present.
            if let roundId = roundId {
                let rd = FetchDescriptor<Round>(predicate: #Predicate { $0.id == roundId })
                if let round = (try? context.fetch(rd))?.first {
                    round.holes.append(h)
                }
                // Else: orphan — `roundIdRef` set above; `applyRound`'s
                // `adoptOrphans` will re-attach when the parent lands.
            } else if let courseId = record["course_id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
                let cd = FetchDescriptor<Course>(predicate: #Predicate { $0.id == courseId })
                if let course = (try? context.fetch(cd))?.first {
                    course.holes.append(h)
                }
            }
        }
    }

    private func applyStroke(context: ModelContext, kind: ChangeKind, id: UUID, record: [String: AnyJSON]) {
        let descriptor = FetchDescriptor<Stroke>(predicate: #Predicate { $0.id == id })
        let existing = (try? context.fetch(descriptor))?.first
        if kind == .delete {
            if let existing = existing { context.delete(existing) }
            return
        }
        let holeNumber = record["hole_number"]?.intValue ?? 0
        let strokeNumber = record["stroke_number"]?.intValue ?? 0
        let lat = record["latitude"]?.doubleValue ?? 0
        let lon = record["longitude"]?.doubleValue ?? 0
        let clubId = record["club_id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? UUID()
        let timestamp = record["timestamp"]?.stringValue.flatMap(Self.parseISODate) ?? Date()
        let isPenalty = record["is_penalty"]?.boolValue ?? false
        let traj = record["trajectory_heading"]?.doubleValue
        let relAlt = record["rel_alt_meters"]?.doubleValue
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let roundId = record["round_id"]?.stringValue.flatMap(UUID.init(uuidString:))

        if let existing = existing {
            existing.holeNumber = holeNumber
            existing.strokeNumber = strokeNumber
            existing.latitude = lat
            existing.longitude = lon
            existing.clubId = clubId
            existing.timestamp = timestamp
            existing.isPenalty = isPenalty
            existing.trajectoryHeading = traj
            existing.relAltMeters = relAlt
            if let roundId = roundId {
                existing.roundIdRef = roundId
                if existing.round == nil {
                    let rd = FetchDescriptor<Round>(predicate: #Predicate { $0.id == roundId })
                    if let round = (try? context.fetch(rd))?.first {
                        round.strokes.append(existing)
                    }
                }
            }
        } else {
            let s = Stroke(id: id, holeNumber: holeNumber, strokeNumber: strokeNumber,
                           coordinate: coord, clubId: clubId, isPenalty: isPenalty,
                           trajectoryHeading: traj, relAltMeters: relAlt, timestamp: timestamp)
            s.roundIdRef = roundId
            context.insert(s)
            if let roundId = roundId {
                let rd = FetchDescriptor<Round>(predicate: #Predicate { $0.id == roundId })
                if let round = (try? context.fetch(rd))?.first {
                    round.strokes.append(s)
                }
                // Else: orphan — `applyRound` will adopt when parent lands.
            }
        }
    }

    private func applyTarget(context: ModelContext, kind: ChangeKind, id: UUID, record: [String: AnyJSON]) {
        let descriptor = FetchDescriptor<Target>(predicate: #Predicate { $0.id == id })
        let existing = (try? context.fetch(descriptor))?.first
        if kind == .delete {
            if let existing = existing { context.delete(existing) }
            return
        }
        let holeNumber = record["hole_number"]?.intValue ?? 0
        let lat = record["latitude"]?.doubleValue ?? 0
        let lon = record["longitude"]?.doubleValue ?? 0
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        if let existing = existing {
            existing.holeNumber = holeNumber; existing.latitude = lat; existing.longitude = lon
        } else {
            let t = Target(id: id, holeNumber: holeNumber, coordinate: coord)
            context.insert(t)
            if let roundId = record["round_id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
                let rd = FetchDescriptor<Round>(predicate: #Predicate { $0.id == roundId })
                if let round = (try? context.fetch(rd))?.first {
                    round.targets.append(t)
                }
            }
        }
    }

    private func applyClubType(context: ModelContext, kind: ChangeKind, id: UUID, record: [String: AnyJSON]) {
        let descriptor = FetchDescriptor<ClubTypeData>(predicate: #Predicate { $0.id == id })
        let existing = (try? context.fetch(descriptor))?.first
        if kind == .delete {
            if let existing = existing { context.delete(existing) }
            return
        }
        let name = record["name"]?.stringValue ?? ""
        let isDefault = record["is_default"]?.boolValue ?? false
        let avg = record["average_distance"]?.intValue
        if let existing = existing {
            existing.name = name; existing.isDefault = isDefault; existing.averageDistance = avg
        } else {
            context.insert(ClubTypeData(id: id, name: name, isDefault: isDefault, averageDistance: avg))
        }
    }

    private func applyClub(context: ModelContext, kind: ChangeKind, id: UUID, record: [String: AnyJSON]) {
        let descriptor = FetchDescriptor<ClubData>(predicate: #Predicate { $0.id == id })
        let existing = (try? context.fetch(descriptor))?.first
        if kind == .delete {
            if let existing = existing { context.delete(existing) }
            return
        }
        let name = record["name"]?.stringValue ?? ""
        let clubTypeId = record["club_type_id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? UUID()
        let isDefault = record["is_default"]?.boolValue ?? false
        if let existing = existing {
            existing.name = name; existing.clubTypeId = clubTypeId; existing.isDefault = isDefault
        } else {
            context.insert(ClubData(id: id, name: name, clubTypeId: clubTypeId, isDefault: isDefault))
        }
    }

    private func applyClubSet(context: ModelContext, kind: ChangeKind, id: UUID, record: [String: AnyJSON]) {
        let descriptor = FetchDescriptor<ClubSet>(predicate: #Predicate { $0.id == id })
        let existing = (try? context.fetch(descriptor))?.first
        if kind == .delete {
            if let existing = existing { context.delete(existing) }
            return
        }
        let name = record["name"]?.stringValue ?? ""
        let isActive = record["is_active"]?.boolValue ?? false
        let dc = record["date_created"]?.stringValue.flatMap(Self.parseISODate) ?? Date()
        let dm = record["date_modified"]?.stringValue.flatMap(Self.parseISODate) ?? Date()
        if let existing = existing {
            existing.name = name; existing.isActive = isActive
            existing.dateCreated = dc; existing.dateModified = dm
        } else {
            context.insert(ClubSet(id: id, name: name, typeSelections: [], isActive: isActive, dateCreated: dc, dateModified: dm))
        }
    }

    // MARK: - Helpers

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
}

// MARK: - AnyJSON convenience accessors

private extension AnyJSON {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var intValue: Int? {
        if case .integer(let i) = self { return i }
        if case .double(let d) = self { return Int(d) }
        return nil
    }
    var doubleValue: Double? {
        if case .double(let d) = self { return d }
        if case .integer(let i) = self { return Double(i) }
        return nil
    }
    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    var arrayValue: [AnyJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }
}

import CoreLocation
