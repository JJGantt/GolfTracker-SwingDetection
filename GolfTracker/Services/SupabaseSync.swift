import Foundation
import CoreLocation

/// Mirrors every local mutation to Supabase. Fire-and-forget from the caller's
/// perspective; failed requests are queued on disk and retried on launch
/// and via a periodic timer.
final class SupabaseSync {
    static let shared = SupabaseSync()

    private let client = SupabaseClient.shared
    private let auth = AuthManager.shared
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
        guard let uid = auth.currentUserId else { return }
        let body: [String: Any] = [
            "id": t.id.uuidString,
            "user_id": uid,
            "name": t.name,
            "is_default": t.isDefault,
            "average_distance": t.averageDistance as Any,
            "updated_at": iso(Date())
        ]
        send(method: "POST", path: "/rest/v1/club_types", payload: body, prefer: "resolution=merge-duplicates")
    }

    func upsertClub(_ c: ClubData) {
        guard let uid = auth.currentUserId else { return }
        let body: [String: Any] = [
            "id": c.id.uuidString,
            "user_id": uid,
            "name": c.name,
            "club_type_id": c.clubTypeId.uuidString,
            "is_default": c.isDefault,
            "updated_at": iso(Date())
        ]
        send(method: "POST", path: "/rest/v1/clubs", payload: body, prefer: "resolution=merge-duplicates")
    }

    func upsertClubSet(_ s: ClubSet) {
        guard let uid = auth.currentUserId else { return }
        let body: [String: Any] = [
            "id": s.id.uuidString,
            "user_id": uid,
            "name": s.name,
            "is_active": s.isActive,
            "date_created": iso(s.dateCreated),
            "date_modified": iso(s.dateModified),
            "updated_at": iso(Date())
        ]
        send(method: "POST", path: "/rest/v1/club_sets", payload: body, prefer: "resolution=merge-duplicates")

        // Replace all child type-selections for this set (simplest sync strategy —
        // delete by club_set_id then re-insert). Small cardinality per set.
        send(method: "DELETE", path: "/rest/v1/club_set_type_selections?club_set_id=eq.\(s.id.uuidString)", payload: nil)
        for sel in s.typeSelections {
            let child: [String: Any] = [
                "club_set_id": s.id.uuidString,
                "type_id": sel.typeId.uuidString,
                "active_club_id": sel.activeClubId?.uuidString as Any
            ]
            send(method: "POST", path: "/rest/v1/club_set_type_selections", payload: child, prefer: "resolution=merge-duplicates")
        }
    }

    func upsertCourse(_ course: Course) {
        guard let uid = auth.currentUserId else { return }
        let body: [String: Any] = [
            "id": course.id.uuidString,
            "user_id": uid,
            "name": course.name,
            "rating": course.rating as Any,
            "slope": course.slope as Any,
            "city": course.city as Any,
            "updated_at": iso(Date())
        ]
        send(method: "POST", path: "/rest/v1/courses", payload: body, prefer: "resolution=merge-duplicates")

        for hole in course.holes {
            upsertHole(hole, courseId: course.id)
        }
    }

    func upsertHole(_ hole: Hole, courseId: UUID) {
        let body: [String: Any] = [
            "id": hole.id.uuidString,
            "course_id": courseId.uuidString,
            "number": hole.number,
            "latitude": hole.latitude as Any,
            "longitude": hole.longitude as Any,
            "par": hole.par as Any,
            "updated_at": iso(Date())
        ]
        send(method: "POST", path: "/rest/v1/holes", payload: body, prefer: "resolution=merge-duplicates")
    }

    func deleteHole(id: UUID) {
        send(method: "DELETE", path: "/rest/v1/holes?id=eq.\(id.uuidString)", payload: nil)
    }

    func deleteCourse(id: UUID) {
        send(method: "DELETE", path: "/rest/v1/courses?id=eq.\(id.uuidString)", payload: nil)
    }

    func upsertRound(_ round: Round) {
        guard let uid = auth.currentUserId else { return }
        let body: [String: Any] = [
            "id": round.id.uuidString,
            "user_id": uid,
            "course_id": round.courseId.uuidString,
            "course_name": round.courseName,
            "date": iso(round.date),
            "current_hole_index": round.currentHoleIndex,
            "completed_holes": Array(round.completedHoles),
            "hole_detection_enabled": round.holeDetectionEnabled as Any,
            "location_test_mode_enabled": round.locationTestModeEnabled as Any,
            "updated_at": iso(Date())
        ]
        send(method: "POST", path: "/rest/v1/rounds", payload: body, prefer: "resolution=merge-duplicates")

        for hole in round.holes {
            upsertRoundHole(hole, roundId: round.id)
        }
    }

    func upsertRoundHole(_ hole: Hole, roundId: UUID) {
        let body: [String: Any] = [
            "id": hole.id.uuidString,
            "round_id": roundId.uuidString,
            "number": hole.number,
            "latitude": hole.latitude as Any,
            "longitude": hole.longitude as Any,
            "par": hole.par as Any
        ]
        send(method: "POST", path: "/rest/v1/round_holes", payload: body, prefer: "resolution=merge-duplicates")
    }

    func upsertStroke(_ stroke: Stroke, roundId: UUID) {
        let body: [String: Any] = [
            "id": stroke.id.uuidString,
            "round_id": roundId.uuidString,
            "hole_number": stroke.holeNumber,
            "stroke_number": stroke.strokeNumber,
            "latitude": stroke.latitude,
            "longitude": stroke.longitude,
            "club_id": stroke.clubId.uuidString,
            "timestamp": iso(stroke.timestamp),
            "is_penalty": stroke.isPenalty,
            "trajectory_heading": stroke.trajectoryHeading as Any,
            "updated_at": iso(Date())
        ]
        send(method: "POST", path: "/rest/v1/strokes", payload: body, prefer: "resolution=merge-duplicates")
    }

    func deleteStroke(id: UUID) {
        send(method: "DELETE", path: "/rest/v1/strokes?id=eq.\(id.uuidString)", payload: nil)
    }

    func upsertTarget(_ target: Target, roundId: UUID) {
        let body: [String: Any] = [
            "id": target.id.uuidString,
            "round_id": roundId.uuidString,
            "hole_number": target.holeNumber,
            "latitude": target.latitude,
            "longitude": target.longitude,
            "updated_at": iso(Date())
        ]
        send(method: "POST", path: "/rest/v1/targets", payload: body, prefer: "resolution=merge-duplicates")
    }

    func deleteTarget(id: UUID) {
        send(method: "DELETE", path: "/rest/v1/targets?id=eq.\(id.uuidString)", payload: nil)
    }

    func deleteRound(id: UUID) {
        send(method: "DELETE", path: "/rest/v1/rounds?id=eq.\(id.uuidString)", payload: nil)
    }

    func deleteClubType(id: UUID) {
        send(method: "DELETE", path: "/rest/v1/club_types?id=eq.\(id.uuidString)", payload: nil)
    }

    func deleteClub(id: UUID) {
        send(method: "DELETE", path: "/rest/v1/clubs?id=eq.\(id.uuidString)", payload: nil)
    }

    func deleteClubSet(id: UUID) {
        send(method: "DELETE", path: "/rest/v1/club_sets?id=eq.\(id.uuidString)", payload: nil)
    }

    /// Wipe every user-keyed row for the current user. Delete-my-data primitive.
    /// Server-side CASCADE handles children once parents are deleted.
    func deleteAllUserData(completion: @escaping (Bool) -> Void) {
        guard let uid = auth.currentUserId else { completion(false); return }
        let paths = [
            "/rest/v1/rounds?user_id=eq.\(uid)",
            "/rest/v1/courses?user_id=eq.\(uid)",
            "/rest/v1/club_sets?user_id=eq.\(uid)",
            "/rest/v1/clubs?user_id=eq.\(uid)",
            "/rest/v1/club_types?user_id=eq.\(uid)"
        ]
        let group = DispatchGroup()
        var allOK = true
        for path in paths {
            group.enter()
            sendNow(method: "DELETE", path: path, payload: nil) { ok in
                if !ok { allOK = false }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(allOK) }
    }

    // MARK: - Queue + transport

    private struct QueuedRequest: Codable {
        let method: String
        let path: String
        let body: Data?
        let prefer: String?
    }

    private func send(method: String, path: String, payload: [String: Any]?, prefer: String? = nil) {
        let body: Data?
        if let payload = payload {
            let cleaned = stripNils(payload)
            body = try? JSONSerialization.data(withJSONObject: cleaned)
        } else {
            body = nil
        }
        let req = QueuedRequest(method: method, path: path, body: body, prefer: prefer)
        attempt(req) { [weak self] ok in
            if !ok { self?.enqueue(req) }
        }
    }

    private func stripNils(_ dict: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in dict {
            if let opt = v as? AnyOptional, opt.isNil { continue }
            out[k] = v
        }
        return out
    }

    private func sendNow(method: String, path: String, payload: [String: Any]?, completion: @escaping (Bool) -> Void) {
        let body = payload.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        attempt(QueuedRequest(method: method, path: path, body: body, prefer: nil), completion: completion)
    }

    private func attempt(_ req: QueuedRequest, completion: @escaping (Bool) -> Void) {
        guard let token = auth.currentAccessToken,
              var request = client.authedRequest(path: req.path, method: req.method, body: req.body, accessToken: token) else {
            completion(false)
            return
        }
        if let prefer = req.prefer {
            request.setValue(prefer, forHTTPHeaderField: "Prefer")
        }
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                dprint("[SupabaseSync] \(req.method) \(req.path) network error: \(error.localizedDescription)")
                completion(false)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 200 && status < 300 {
                completion(true)
            } else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                dprint("[SupabaseSync] \(req.method) \(req.path) HTTP \(status): \(body)")
                // 4xx is a client/auth error — don't retry. 5xx / 0 retry.
                completion(status >= 500 || status == 0)
            }
        }.resume()
    }

    private func enqueue(_ req: QueuedRequest) {
        queueLock.lock(); defer { queueLock.unlock() }
        var queue = loadQueue()
        queue.append(req)
        saveQueue(queue)
    }

    private func loadQueue() -> [QueuedRequest] {
        guard let data = try? Data(contentsOf: queueURL),
              let queue = try? JSONDecoder().decode([QueuedRequest].self, from: data) else {
            return []
        }
        return queue
    }

    private func saveQueue(_ queue: [QueuedRequest]) {
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
        dprint("[SupabaseSync] draining \(queue.count) queued requests")
        for req in queue {
            attempt(req) { [weak self] ok in
                if !ok { self?.enqueue(req) }
            }
        }
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

private protocol AnyOptional {
    var isNil: Bool { get }
}

extension Optional: AnyOptional {
    var isNil: Bool { self == nil }
}

