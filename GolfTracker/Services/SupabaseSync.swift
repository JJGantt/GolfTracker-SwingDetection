import Foundation
import CoreLocation
import Supabase
import SwiftData

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
            "sort_order": t.sortOrder.map(AnyCodableValue.int) ?? .null,
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

    /// Write a green the user placed into the COURSE's shared hole record.
    ///
    /// Keyed on `(course_id, number)` rather than on a row id, because the
    /// caller placing the green is usually the watch, whose `round.holes` are
    /// per-round copies with their own ids and no knowledge of the course-level
    /// row. The unique constraint on `(course_id, number)` makes that upsert
    /// exact.
    ///
    /// This exists because `holes` had precisely one writer — `RoundResolver`,
    /// building rows from OSM and requiring an OSM `ref` and green point. A
    /// course OSM has never heard of therefore ended up with zero hole rows no
    /// matter how many greens were placed by hand: Wolf Hollow had 15 greens
    /// placed across 10 rounds and 0 rows here. A green the user selected is
    /// authoritative; OSM is a convenience for courses it happens to know.
    func upsertCourseHoleLocation(courseId: UUID,
                                  number: Int,
                                  latitude: Double,
                                  longitude: Double,
                                  par: Int?) {
        var body: [String: AnyCodableValue] = [
            "id": .string(UUID().uuidString),   // only used when inserting
            "course_id": .string(courseId.uuidString),
            "number": .int(number),
            "latitude": .double(latitude),
            "longitude": .double(longitude),
            "updated_at": .string(iso(Date()))
        ]
        if let par { body["par"] = .int(par) }
        upsert(table: "holes", values: body, onConflict: "course_id,number")
    }

    /// User's pick of which blob (or manual coord) is hole N at course X.
    /// Cross-user voting on these rows produces the canonical green at
    /// round-start for users who haven't played the course yet.
    func upsertCourseHolePick(courseId: UUID,
                              holeNumber: Int,
                              blobId: UUID?,
                              latitude: Double?,
                              longitude: Double?,
                              par: Int?) {
        guard let uid = currentUserId else { return }
        let body: [String: AnyCodableValue] = [
            "user_id": .string(uid),
            "course_id": .string(courseId.uuidString),
            "hole_number": .int(holeNumber),
            "blob_id": blobId.map { .string($0.uuidString) } ?? .null,
            "latitude": latitude.map(AnyCodableValue.double) ?? .null,
            "longitude": longitude.map(AnyCodableValue.double) ?? .null,
            "par": par.map(AnyCodableValue.int) ?? .null,
            "updated_at": .string(iso(Date()))
        ]
        upsert(table: "course_hole_picks", values: body, onConflict: "user_id,course_id,hole_number", includeNulls: true)
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
            "current_hole_number": .int(round.currentHoleNumber),
            "completed_holes": .intArray(Array(round.completedHoles)),
            "hole_detection_enabled": round.holeDetectionEnabled.map(AnyCodableValue.bool) ?? .null,
            "location_test_mode_enabled": round.locationTestModeEnabled.map(AnyCodableValue.bool) ?? .null,
            "selected_tee_id": round.selectedTeeId.map { .string($0.uuidString) } ?? .null,
            "ended_at": round.endedAt.map { .string(iso($0)) } ?? .null,
            "last_activity_at": round.lastActivityAt.map { .string(iso($0)) } ?? .null,
            "updated_at": .string(iso(Date()))
        ]
        upsert(table: "rounds", values: body, onConflict: "id")
    }

    /// Every hole of the round. For a new round; a changed or added hole goes
    /// through `upsertRoundHole` alone. `upsertRound` used to send all of them
    /// on every call, so each stroke and hole change was 19 writes that could
    /// land in any order.
    func upsertRoundHoles(_ round: Round) {
        for hole in round.holes {
            upsertRoundHole(hole, roundId: round.id)
        }
    }

    /// Moving to another hole: the two columns that changed, not the round.
    func updateCurrentHole(_ round: Round) {
        var values: [String: AnyCodableValue] = [
            "current_hole_number": .int(round.currentHoleNumber),
            "updated_at": .string(iso(Date()))
        ]
        if let at = round.lastActivityAt { values["last_activity_at"] = .string(iso(at)) }
        update(table: "rounds", values: values, filterColumn: "id", filterValue: round.id.uuidString)
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

    func deleteRoundHole(id: UUID) {
        delete(table: "round_holes", filterColumn: "id", filterValue: id.uuidString)
    }

    // MARK: - Round hole repair

    private static let pendingRewriteKey = "roundHolesPendingRewrite"

    /// Rounds whose `round_holes` rows must be rewritten to match their local
    /// holes (`ModelContext.separateRoundHolesFromCourseHoles`). Kept until
    /// the rewrite lands, so a launch without a connection retries next time.
    func markRoundHolesForRewrite(_ roundIds: [UUID]) {
        guard !roundIds.isEmpty else { return }
        let current = Set(UserDefaults.standard.stringArray(forKey: Self.pendingRewriteKey) ?? [])
        UserDefaults.standard.set(Array(current.union(roundIds.map(\.uuidString))), forKey: Self.pendingRewriteKey)
    }

    private func finishRoundHoleRewrite(_ roundId: String) {
        let current = UserDefaults.standard.stringArray(forKey: Self.pendingRewriteKey) ?? []
        UserDefaults.standard.set(current.filter { $0 != roundId }, forKey: Self.pendingRewriteKey)
    }

    private struct RoundHoleRow: Encodable {
        let id: String
        let round_id: String
        let number: Int
        let latitude: Double?
        let longitude: Double?
        let par: Int?
        let tee_id: String?

        // Nulls written out: every row in one upsert must carry the same keys.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(round_id, forKey: .round_id)
            try c.encode(number, forKey: .number)
            try c.encode(latitude, forKey: .latitude)
            try c.encode(longitude, forKey: .longitude)
            try c.encode(par, forKey: .par)
            try c.encode(tee_id, forKey: .tee_id)
        }
        enum CodingKeys: String, CodingKey { case id, round_id, number, latitude, longitude, par, tee_id }
    }

    /// For each pending round, make its `round_holes` rows exactly its local
    /// holes: delete the rows whose ids aren't local, then upsert the local
    /// ones. Delete first because `(round_id, number)` is unique and the
    /// copies carry new ids. Every device computes the same ids
    /// (`Hole.roundHoleId`), so two devices doing this land on the same rows.
    @MainActor
    func rewritePendingRoundHoles(context: ModelContext) async {
        let pending = UserDefaults.standard.stringArray(forKey: Self.pendingRewriteKey) ?? []
        guard !pending.isEmpty, currentUserId != nil else { return }
        struct IdRow: Decodable { let id: String }
        for idString in pending {
            guard let roundId = UUID(uuidString: idString),
                  let round = (try? context.fetch(FetchDescriptor<Round>(predicate: #Predicate { $0.id == roundId })))?.first else {
                finishRoundHoleRewrite(idString)
                continue
            }
            let rows = round.holes.map {
                RoundHoleRow(id: $0.id.uuidString, round_id: idString, number: $0.number,
                             latitude: $0.latitude, longitude: $0.longitude, par: $0.par,
                             tee_id: $0.teeId?.uuidString)
            }
            do {
                let exists: [IdRow] = try await supabase.from("rounds").select("id").eq("id", value: idString).execute().value
                if exists.isEmpty {
                    finishRoundHoleRewrite(idString)
                    continue
                }
                var stale = supabase.from("round_holes").delete().eq("round_id", value: idString)
                if !rows.isEmpty {
                    stale = stale.not("id", operator: .in, value: "(" + rows.map(\.id).joined(separator: ",") + ")")
                }
                try await stale.execute()
                if !rows.isEmpty {
                    try await supabase.from("round_holes").upsert(rows, onConflict: "id").execute()
                }
                finishRoundHoleRewrite(idString)
                ClientEventLogger.log("roundHoles.rewritten", detail: [
                    "roundId": .string(idString), "holes": .integer(rows.count)
                ])
            } catch {
                ClientEventLogger.log("roundHoles.rewrite.failed", detail: [
                    "roundId": .string(idString), "error": .string("\(error)")
                ])
            }
        }
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
            "rel_alt_meters": stroke.relAltMeters.map(AnyCodableValue.double) ?? .null,
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
        enum Kind: String, Codable { case upsert, delete, update }
        let kind: Kind
        let table: String
        // For upsert: JSON-encoded payload + onConflict column list
        let payloadJSON: Data?
        let onConflict: String?
        // For delete: column + value
        let filterColumn: String?
        let filterValue: String?
    }

    private func upsert(table: String, values: [String: AnyCodableValue], onConflict: String, includeNulls: Bool = false) {
        let body = encodeValues(values, includeNulls: includeNulls)
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

    private func update(table: String, values: [String: AnyCodableValue], filterColumn: String, filterValue: String) {
        let op = QueuedOperation(
            kind: .update,
            table: table,
            payloadJSON: encodeValues(values),
            onConflict: nil,
            filterColumn: filterColumn,
            filterValue: filterValue
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
                case .update:
                    guard let body = op.payloadJSON,
                          let json = try? JSONDecoder().decode(AnyJSON.self, from: body),
                          let col = op.filterColumn, let val = op.filterValue else {
                        completion(false); return
                    }
                    let q = try supabase.from(op.table).update(json)
                    try await q.eq(col, value: val).execute()
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

    /// Encode a [String: AnyCodableValue] dict to JSON Data. By default
    /// drops nulls — most upserts are partial updates where unspecified
    /// fields should keep their existing server-side value. Pass
    /// `includeNulls: true` for tables where switching a field to NULL is
    /// itself the intent (e.g. course_hole_picks toggling between blob_id
    /// and manual lat/lon — the opposite field must be cleared).
    private func encodeValues(_ values: [String: AnyCodableValue], includeNulls: Bool = false) -> Data? {
        var clean: [String: Any] = [:]
        for (k, v) in values {
            if v.isNull {
                if includeNulls { clean[k] = NSNull() }
            } else {
                clean[k] = v.jsonValue
            }
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
