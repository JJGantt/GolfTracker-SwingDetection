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
    private var context: ModelContext? {
        guard let modelContainer = modelContainer else { return nil }
        return ModelContext(modelContainer)
    }

    private var subscriptions: [Task<Void, Never>] = []
    private var activeChannel: RealtimeChannelV2?
    private var activeUserId: String?

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

    private func restart(forUserId userId: String) async {
        await teardown()
        activeUserId = userId

        let channel = supabase.realtime.channel("user:\(userId)")
        activeChannel = channel

        // user-keyed tables: filter server-side
        wireUserKeyedTable(channel, "rounds", userId: userId)
        wireUserKeyedTable(channel, "courses", userId: userId)
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

        do {
            try await channel.subscribeWithError()
            dprint("📡 [RealtimeSync] subscribed for user \(userId)")
        } catch {
            dprint("📡 [RealtimeSync] subscribe failed: \(error.localizedDescription)")
        }
    }

    private func teardown() async {
        for task in subscriptions { task.cancel() }
        subscriptions.removeAll()
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
        case "holes":    applyHole(context: context, kind: kind, id: id, record: record)
        case "round_holes": applyHole(context: context, kind: kind, id: id, record: record)
        case "strokes":  applyStroke(context: context, kind: kind, id: id, record: record)
        case "targets":  applyTarget(context: context, kind: kind, id: id, record: record)
        case "club_types":  applyClubType(context: context, kind: kind, id: id, record: record)
        case "clubs":       applyClub(context: context, kind: kind, id: id, record: record)
        case "club_sets":   applyClubSet(context: context, kind: kind, id: id, record: record)
        default: break
        }
        try? context.save()
        // Notify the platform store so views observing it (which use computed
        // properties like currentRound that re-fetch on each access) actually
        // re-render when these mutations land. Without this, the iPhone can
        // change holes / record strokes and the watch's view won't update
        // until the user navigates the watch UI manually.
        Task { @MainActor in
            #if os(watchOS)
            WatchDataStore.shared.objectWillChange.send()
            #else
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
        if let existing = existing {
            existing.courseId = courseId
            existing.courseName = courseName
            existing.date = date
            existing.currentHoleIndex = currentHoleIndex
            existing.completedHolesArray = completed
            existing.holeDetectionEnabled = record["hole_detection_enabled"]?.boolValue
            existing.locationTestModeEnabled = record["location_test_mode_enabled"]?.boolValue
            existing.selectedTeeId = selectedTeeId
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
            context.insert(r)
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
        if let existing = existing {
            existing.name = name; existing.rating = rating; existing.slope = slope; existing.city = city
        } else {
            context.insert(Course(id: id, name: name, holes: [], rating: rating, slope: slope, city: city))
        }
    }

    private func applyHole(context: ModelContext, kind: ChangeKind, id: UUID, record: [String: AnyJSON]) {
        let descriptor = FetchDescriptor<Hole>(predicate: #Predicate { $0.id == id })
        let existing = (try? context.fetch(descriptor))?.first
        if kind == .delete {
            if let existing = existing { context.delete(existing) }
            return
        }
        let number = record["number"]?.intValue ?? 0
        let lat = record["latitude"]?.doubleValue
        let lon = record["longitude"]?.doubleValue
        let par = record["par"]?.intValue
        let teeId = record["tee_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        if let existing = existing {
            existing.number = number; existing.latitude = lat; existing.longitude = lon; existing.par = par
            existing.teeId = teeId
        } else {
            let h = Hole(id: id, number: number)
            h.latitude = lat; h.longitude = lon; h.par = par; h.teeId = teeId
            context.insert(h)
            // Best-effort link to its round via round_id, if present.
            if let roundId = record["round_id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
                let rd = FetchDescriptor<Round>(predicate: #Predicate { $0.id == roundId })
                if let round = (try? context.fetch(rd))?.first {
                    round.holes.append(h)
                }
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
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)

        if let existing = existing {
            existing.holeNumber = holeNumber
            existing.strokeNumber = strokeNumber
            existing.latitude = lat
            existing.longitude = lon
            existing.clubId = clubId
            existing.timestamp = timestamp
            existing.isPenalty = isPenalty
            existing.trajectoryHeading = traj
        } else {
            let s = Stroke(id: id, holeNumber: holeNumber, strokeNumber: strokeNumber,
                           coordinate: coord, clubId: clubId, isPenalty: isPenalty,
                           trajectoryHeading: traj, timestamp: timestamp)
            context.insert(s)
            if let roundId = record["round_id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
                let rd = FetchDescriptor<Round>(predicate: #Predicate { $0.id == roundId })
                if let round = (try? context.fetch(rd))?.first {
                    round.strokes.append(s)
                }
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
