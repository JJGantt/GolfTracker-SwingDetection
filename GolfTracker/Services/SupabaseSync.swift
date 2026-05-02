import Foundation
import CoreLocation
import Supabase

/// Mirrors every local mutation to Supabase via the supabase-swift SDK.
/// Fire-and-forget from the caller's perspective; failed requests are queued
/// on disk and retried on launch and via a periodic timer (the SDK doesn't
/// provide offline queueing, so we still own that piece).
final class SupabaseSync {
    static let shared = SupabaseSync()

    private let supabase = SupabaseManager.shared

    /// Cross-platform user-id source. iOS uses AuthManager (which drives the
    /// SIWA flow); watchOS uses WatchAuthSession (which mirrors the SDK
    /// session forwarded from the iPhone).
    private var currentUserId: String? {
        #if os(watchOS)
        return WatchAuthSession.shared.currentUserId
        #else
        return AuthManager.shared.currentUserId
        #endif
    }
    private var currentAccessToken: String? {
        #if os(watchOS)
        return WatchAuthSession.shared.session?.accessToken
        #else
        return AuthManager.shared.currentAccessToken
        #endif
    }
    private let queueURL: URL
    private let queueLock = NSLock()
    private var retryTimer: Timer?

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.queueURL = dir.appendingPathComponent("supabase_sync_queue.json")
        startRetryTimer()
    }

    // MARK: - Public entrypoints

    func upsertClubType(_ t: ClubTypeData) {
        guard let uid = currentUserId else { return }
        let body: [String: AnyCodableValue] = [
            "id": .string(t.id.uuidString),
            "user_id": .string(uid),
            "name": .string(t.name),
            "is_default": .bool(t.isDefault),
            "average_distance": t.averageDistance.map(AnyCodableValue.int) ?? .null,
            "updated_at": .string(iso(Date()))
        ]
        upsert(table: "club_types", values: body, onConflict: "id")
    }

    func upsertClub(_ c: ClubData) {
        guard let uid = currentUserId else { return }
        let body: [String: AnyCodableValue] = [
            "id": .string(c.id.uuidString),
            "user_id": .string(uid),
            "name": .string(c.name),
            "club_type_id": .string(c.clubTypeId.uuidString),
            "is_default": .bool(c.isDefault),
            "updated_at": .string(iso(Date()))
        ]
        upsert(table: "clubs", values: body, onConflict: "id")
    }

    func upsertClubSet(_ s: ClubSet) {
        guard let uid = currentUserId else { return }
        let body: [String: AnyCodableValue] = [
            "id": .string(s.id.uuidString),
            "user_id": .string(uid),
            "name": .string(s.name),
            "is_active": .bool(s.isActive),
            "date_created": .string(iso(s.dateCreated)),
            "date_modified": .string(iso(s.dateModified)),
            "updated_at": .string(iso(Date()))
        ]
        upsert(table: "club_sets", values: body, onConflict: "id")

        // Replace all child type-selections for this set.
        delete(table: "club_set_type_selections", filterColumn: "club_set_id", filterValue: s.id.uuidString)
        for sel in s.typeSelections {
            let child: [String: AnyCodableValue] = [
                "club_set_id": .string(s.id.uuidString),
                "type_id": .string(sel.typeId.uuidString),
                "active_club_id": sel.activeClubId.map { .string($0.uuidString) } ?? .null
            ]
            upsert(table: "club_set_type_selections", values: child, onConflict: "club_set_id,type_id")
        }
    }

    /// Mirrors local edits to a shared course row. Does NOT write
    /// `created_by` or `osm_polygons` — those are owned by RoundResolver on
    /// initial INSERT (see migration 00026). Updates here only carry
    /// user-edit-able fields plus the geo centroid (which can be backfilled
    /// from holes if missing).
    func upsertCourse(_ course: Course) {
        guard currentUserId != nil else { return }
        var body: [String: AnyCodableValue] = [
            "id": .string(course.id.uuidString),
            "name": .string(course.name),
            "rating": course.rating.map(AnyCodableValue.double) ?? .null,
            "slope": course.slope.map(AnyCodableValue.int) ?? .null,
            "city": course.city.map(AnyCodableValue.string) ?? .null,
            "external_course_id": course.externalCourseId.map(AnyCodableValue.string) ?? .null,
            "updated_at": .string(iso(Date()))
        ]
        if let lat = course.centerLat { body["center_lat"] = .double(lat) }
        if let lon = course.centerLon { body["center_lon"] = .double(lon) }
        if let osmId = course.osmId { body["osm_id"] = .int(Int(osmId)) }
        upsert(table: "courses", values: body, onConflict: "id")

        for hole in course.holes {
            upsertHole(hole, courseId: course.id)
        }
    }

    func upsertHole(_ hole: Hole, courseId: UUID) {
        let body: [String: AnyCodableValue] = [
            "id": .string(hole.id.uuidString),
            "course_id": .string(courseId.uuidString),
            "number": .int(hole.number),
            "latitude": hole.latitude.map(AnyCodableValue.double) ?? .null,
            "longitude": hole.longitude.map(AnyCodableValue.double) ?? .null,
            "par": hole.par.map(AnyCodableValue.int) ?? .null,
            "updated_at": .string(iso(Date()))
        ]
        upsert(table: "holes", values: body, onConflict: "id")
    }

    func deleteHole(id: UUID) {
        delete(table: "holes", filterColumn: "id", filterValue: id.uuidString)
    }

    func deleteCourse(id: UUID) {
        delete(table: "courses", filterColumn: "id", filterValue: id.uuidString)
    }

    func upsertRound(_ round: Round) {
        guard let uid = currentUserId else { return }
        let body: [String: AnyCodableValue] = [
            "id": .string(round.id.uuidString),
            "user_id": .string(uid),
            "course_id": .string(round.courseId.uuidString),
            "course_name": .string(round.courseName),
            "date": .string(iso(round.date)),
            "current_hole_index": .int(round.currentHoleIndex),
            "completed_holes": .intArray(Array(round.completedHoles)),
            "hole_detection_enabled": round.holeDetectionEnabled.map(AnyCodableValue.bool) ?? .null,
            "location_test_mode_enabled": round.locationTestModeEnabled.map(AnyCodableValue.bool) ?? .null,
            "selected_tee_id": round.selectedTeeId.map { .string($0.uuidString) } ?? .null,
            "ended_at": round.endedAt.map { .string(iso($0)) } ?? .null,
            "last_activity_at": round.lastActivityAt.map { .string(iso($0)) } ?? .null,
            "updated_at": .string(iso(Date()))
        ]
        upsert(table: "rounds", values: body, onConflict: "id")

        for hole in round.holes {
            upsertRoundHole(hole, roundId: round.id)
        }
    }

    func upsertRoundHole(_ hole: Hole, roundId: UUID) {
        let body: [String: AnyCodableValue] = [
            "id": .string(hole.id.uuidString),
            "round_id": .string(roundId.uuidString),
            "number": .int(hole.number),
            "latitude": hole.latitude.map(AnyCodableValue.double) ?? .null,
            "longitude": hole.longitude.map(AnyCodableValue.double) ?? .null,
            "par": hole.par.map(AnyCodableValue.int) ?? .null,
            "tee_id": hole.teeId.map { .string($0.uuidString) } ?? .null
        ]
        upsert(table: "round_holes", values: body, onConflict: "id")
    }

    func upsertStroke(_ stroke: Stroke, roundId: UUID) {
        let body: [String: AnyCodableValue] = [
            "id": .string(stroke.id.uuidString),
            "round_id": .string(roundId.uuidString),
            "hole_number": .int(stroke.holeNumber),
            "stroke_number": .int(stroke.strokeNumber),
            "latitude": .double(stroke.latitude),
            "longitude": .double(stroke.longitude),
            "club_id": .string(stroke.clubId.uuidString),
            "timestamp": .string(iso(stroke.timestamp)),
            "is_penalty": .bool(stroke.isPenalty),
            "trajectory_heading": stroke.trajectoryHeading.map(AnyCodableValue.double) ?? .null,
            "updated_at": .string(iso(Date()))
        ]
        upsert(table: "strokes", values: body, onConflict: "id")
    }

    func deleteStroke(id: UUID) {
        delete(table: "strokes", filterColumn: "id", filterValue: id.uuidString)
    }

    func upsertTarget(_ target: Target, roundId: UUID) {
        let body: [String: AnyCodableValue] = [
            "id": .string(target.id.uuidString),
            "round_id": .string(roundId.uuidString),
            "hole_number": .int(target.holeNumber),
            "latitude": .double(target.latitude),
            "longitude": .double(target.longitude),
            "updated_at": .string(iso(Date()))
        ]
        upsert(table: "targets", values: body, onConflict: "id")
    }

    func deleteTarget(id: UUID) {
        delete(table: "targets", filterColumn: "id", filterValue: id.uuidString)
    }

    func deleteRound(id: UUID) {
        delete(table: "rounds", filterColumn: "id", filterValue: id.uuidString)
    }

    func deleteClubType(id: UUID) {
        delete(table: "club_types", filterColumn: "id", filterValue: id.uuidString)
    }

    func deleteClub(id: UUID) {
        delete(table: "clubs", filterColumn: "id", filterValue: id.uuidString)
    }

    func deleteClubSet(id: UUID) {
        delete(table: "club_sets", filterColumn: "id", filterValue: id.uuidString)
    }

    /// Wipe every user-keyed row for the current user. Server-side CASCADE
    /// handles children once parents are deleted.
    func deleteAllUserData(completion: @escaping (Bool) -> Void) {
        guard let uid = currentUserId else { completion(false); return }
        Task {
            var allOK = true
            for table in ["rounds", "courses", "club_sets", "clubs", "club_types"] {
                do {
                    try await supabase.from(table).delete().eq("user_id", value: uid).execute()
                } catch {
                    dprint("[SupabaseSync] delete-all \(table) failed: \(error)")
                    allOK = false
                }
            }
            await MainActor.run { completion(allOK) }
        }
    }

    // MARK: - Queue + transport

    /// Queueable representation of a Postgrest mutation. Stored on disk between
    /// app launches so writes survive offline → relaunch transitions.
    private struct QueuedOperation: Codable {
        enum Kind: String, Codable { case upsert, delete }
        let kind: Kind
        let table: String
        // For upsert: JSON-encoded payload + onConflict column list
        let payloadJSON: Data?
        let onConflict: String?
        // For delete: column + value
        let filterColumn: String?
        let filterValue: String?
    }

    private func upsert(table: String, values: [String: AnyCodableValue], onConflict: String) {
        let body = encodeValues(values)
        let op = QueuedOperation(
            kind: .upsert,
            table: table,
            payloadJSON: body,
            onConflict: onConflict,
            filterColumn: nil,
            filterValue: nil
        )
        attempt(op) { [weak self] ok in
            if !ok { self?.enqueue(op) }
        }
    }

    private func delete(table: String, filterColumn: String, filterValue: String) {
        let op = QueuedOperation(
            kind: .delete,
            table: table,
            payloadJSON: nil,
            onConflict: nil,
            filterColumn: filterColumn,
            filterValue: filterValue
        )
        attempt(op) { [weak self] ok in
            if !ok { self?.enqueue(op) }
        }
    }

    private func attempt(_ op: QueuedOperation, completion: @escaping (Bool) -> Void) {
        guard currentAccessToken != nil else { completion(false); return }
        Task {
            do {
                switch op.kind {
                case .upsert:
                    guard let body = op.payloadJSON,
                          let json = try? JSONDecoder().decode(AnyJSON.self, from: body),
                          let onConflict = op.onConflict else {
                        completion(false); return
                    }
                    let q = try supabase.from(op.table).upsert(json, onConflict: onConflict)
                    try await q.execute()
                    completion(true)
                case .delete:
                    guard let col = op.filterColumn, let val = op.filterValue else {
                        completion(false); return
                    }
                    try await supabase.from(op.table).delete().eq(col, value: val).execute()
                    completion(true)
                }
            } catch {
                dprint("[SupabaseSync] \(op.kind.rawValue) \(op.table) failed: \(error)")
                completion(false)
            }
        }
    }

    private func enqueue(_ op: QueuedOperation) {
        queueLock.lock(); defer { queueLock.unlock() }
        var queue = loadQueue()
        queue.append(op)
        saveQueue(queue)
    }

    private func loadQueue() -> [QueuedOperation] {
        guard let data = try? Data(contentsOf: queueURL),
              let queue = try? JSONDecoder().decode([QueuedOperation].self, from: data) else {
            return []
        }
        return queue
    }

    private func saveQueue(_ queue: [QueuedOperation]) {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        try? data.write(to: queueURL)
    }

    private func startRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.drainQueue()
        }
        DispatchQueue.main.async { [weak self] in self?.drainQueue() }
    }

    private func drainQueue() {
        queueLock.lock()
        let queue = loadQueue()
        saveQueue([])
        queueLock.unlock()
        guard !queue.isEmpty else { return }
        dprint("[SupabaseSync] draining \(queue.count) queued operations")
        for op in queue {
            attempt(op) { [weak self] ok in
                if !ok { self?.enqueue(op) }
            }
        }
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// Encode a [String: AnyCodableValue] dict to JSON Data, dropping nulls.
    private func encodeValues(_ values: [String: AnyCodableValue]) -> Data? {
        var clean: [String: Any] = [:]
        for (k, v) in values where !v.isNull {
            clean[k] = v.jsonValue
        }
        return try? JSONSerialization.data(withJSONObject: clean)
    }
}

// MARK: - AnyCodableValue

/// A small enum to express the value types we send over the wire. Replaces the
/// previous untyped `[String: Any]` payloads with something we can reason about
/// at compile time, while still serializing to plain JSON.
private enum AnyCodableValue {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case intArray([Int])
    case null

    var isNull: Bool {
        if case .null = self { return true } else { return false }
    }

    var jsonValue: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .intArray(let a): return a
        case .null: return NSNull()
        }
    }
}
