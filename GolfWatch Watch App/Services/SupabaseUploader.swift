import Foundation

/// Uploads swing detection events to Supabase for ML analysis.
/// Manages the pending-event lifecycle: each detection is held until
/// explicitly accepted/rejected or flushed by the next detection.
class SupabaseUploader {
    static let shared = SupabaseUploader()

    // MARK: - Configuration

    private let projectURL = "https://oumnicnvayqrbfbljgyl.supabase.co"
    private let apiKey = "sb_publishable_i0loB-AZw2qGokBJzHGSKA_VGgAgjBi"
    private let storageBucket = "swing-motion"

    /// When true, every detection immediately uploads as false_positive/high.
    /// For false-positive farming during casual wear.
    var rejectAll: Bool = false {
        didSet { UserDefaults.standard.set(rejectAll, forKey: "supabaseRejectAll") }
    }

    // MARK: - Pending Event

    struct PendingEvent {
        let id: UUID
        let metadata: SwingDetectionManager.DetectionMetadata
        let motionSlice: [SwingDetectionManager.RecordedDataPoint]
        let rawAccelSlice: [SwingDetectionManager.RawAccelDataPoint]
        let clubType: String?
        var label: String       // "positive" or "false_positive"
        var confidence: String  // "high" or "low"
    }

    private var pending: PendingEvent?
    private let queue = DispatchQueue(label: "supabase-uploader", qos: .utility)

    // MARK: - Init

    private init() {
        if UserDefaults.standard.object(forKey: "supabaseRejectAll") != nil {
            rejectAll = UserDefaults.standard.bool(forKey: "supabaseRejectAll")
        }
    }

    // MARK: - Event Lifecycle

    /// Called from `fireSmartDetection` on every detection.
    /// Flushes any previous pending event, then holds the new one.
    func onSwingDetected(
        metadata: SwingDetectionManager.DetectionMetadata,
        motionSlice: [SwingDetectionManager.RecordedDataPoint],
        rawAccelSlice: [SwingDetectionManager.RawAccelDataPoint] = [],
        clubType: String?,
        autoAdd: Bool
    ) {
        // Flush previous pending event with low confidence (implicit — user didn't act)
        if let prev = pending {
            upload(event: prev)
        }

        if rejectAll {
            // Farming mode: immediate upload, no pending
            let event = PendingEvent(
                id: UUID(),
                metadata: metadata,
                motionSlice: motionSlice,
                rawAccelSlice: rawAccelSlice,
                clubType: clubType,
                label: "false_positive",
                confidence: "high"
            )
            upload(event: event)
            pending = nil
            return
        }

        // Hold as pending with tentative label based on mode
        pending = PendingEvent(
            id: UUID(),
            metadata: metadata,
            motionSlice: motionSlice,
            rawAccelSlice: rawAccelSlice,
            clubType: clubType,
            label: autoAdd ? "positive" : "false_positive",
            confidence: "low"
        )
    }

    /// Called when user taps to add the stroke (manual-add mode).
    /// Flips the pending label to positive with high confidence.
    func onSwingAccepted() {
        pending?.label = "positive"
        pending?.confidence = "high"
    }

    /// Called when user undoes an auto-added stroke.
    /// Immediately flushes as false_positive with high confidence.
    func onSwingRejected() {
        guard var event = pending else { return }
        event.label = "false_positive"
        event.confidence = "high"
        upload(event: event)
        pending = nil
    }

    /// Flush whatever's pending (e.g., on round end or monitoring stop).
    func flushPending() {
        guard let event = pending else { return }
        upload(event: event)
        pending = nil
    }

    // MARK: - Upload

    private func upload(event: PendingEvent) {
        let eventCopy = event
        queue.async { [weak self] in
            guard let self = self else { return }
            // Resolve a valid auth token once, then fan out to the three uploads.
            // If we're not signed in, drop the event with a clear log — there's no
            // anonymous fallback, and storing it locally would silently mask the auth gap.
            WatchAuthSession.shared.validAccessToken { result in
                switch result {
                case .failure(let err):
                    dprint("⌚ [SupabaseUploader] Drop event \(eventCopy.id.uuidString) — no auth: \(err)")
                case .success(let token):
                    guard let userId = WatchAuthSession.shared.currentUserId else {
                        dprint("⌚ [SupabaseUploader] Drop event — token without userId")
                        return
                    }
                    self.uploadMetadata(event: eventCopy, token: token, userId: userId)
                    self.uploadMotionCSV(event: eventCopy, token: token, userId: userId)
                    self.uploadRawAccelCSV(event: eventCopy, token: token, userId: userId)
                }
            }
        }
    }

    private func uploadMetadata(event: PendingEvent, token: String, userId: String) {
        let meta = event.metadata
        let storagePath = "\(userId)/\(event.id.uuidString).csv"

        let payload: [String: Any?] = [
            "id": event.id.uuidString,
            "classification": event.clubType ?? "unknown",
            "swing_type": event.clubType ?? "unknown",
            "label": event.label,
            "confidence": event.confidence,
            "fs_peak_rot_mag": meta.fsPeakRotMag,
            "bs_peak_rot_mag": meta.bsRotMag,
            "fs_bs_ratio": meta.fsBsRatio,
            "peak_acceleration": meta.peakAcceleration,
            "contact_tv": meta.contactTV,
            "contact_n": meta.contactN,
            "extrema_spread": meta.extremaSpread,
            "baseline_tv": meta.baselineTV,
            "setup_duration": meta.setupDuration,
            "bs_to_fs_gap": meta.fsPeakT - meta.bsTopT,
            "club_type": event.clubType,
            "detection_mode": "unifDetect",
            "storage_path": storagePath
        ]
        let cleanPayload = payload.compactMapValues { $0 }
        guard let body = try? JSONSerialization.data(withJSONObject: cleanPayload) else {
            dprint("⌚ [SupabaseUploader] Failed to encode metadata payload")
            return
        }

        sendAuthed(
            urlString: "\(projectURL)/rest/v1/swing_events",
            method: "POST",
            contentType: "application/json",
            body: body,
            token: token,
            event: event,
            tag: "metadata(\(event.label)/\(event.confidence))"
        )
    }

    private func uploadMotionCSV(event: PendingEvent, token: String, userId: String) {
        guard !event.motionSlice.isEmpty else {
            dprint("⌚ [SupabaseUploader] No motion data to upload")
            return
        }
        let storagePath = "\(userId)/\(event.id.uuidString).csv"
        var csv = "SensorTime,UserAccelX,UserAccelY,UserAccelZ,UserAccelMag,RotationX,RotationY,RotationZ,RotationMag,GravityX,GravityY,GravityZ,Pitch,Roll,Yaw\n"
        let f = { (v: Double) -> String in String(format: "%.4f", v) }
        for dp in event.motionSlice {
            csv += "\(f(dp.sensorTime)),\(f(dp.userAccelX)),\(f(dp.userAccelY)),\(f(dp.userAccelZ)),\(f(dp.userAccelMag)),\(f(dp.rotationX)),\(f(dp.rotationY)),\(f(dp.rotationZ)),\(f(dp.rotationMag)),\(f(dp.gravityX)),\(f(dp.gravityY)),\(f(dp.gravityZ)),\(f(dp.pitch)),\(f(dp.roll)),\(f(dp.yaw))\n"
        }
        guard let csvData = csv.data(using: .utf8) else { return }
        sendAuthed(
            urlString: "\(projectURL)/storage/v1/object/\(storageBucket)/\(storagePath)",
            method: "POST",
            contentType: "text/csv",
            body: csvData,
            token: token,
            event: event,
            tag: "motionCSV(\(event.motionSlice.count) samples)"
        )
    }

    private func uploadRawAccelCSV(event: PendingEvent, token: String, userId: String) {
        guard !event.rawAccelSlice.isEmpty else { return }
        let storagePath = "\(userId)/\(event.id.uuidString)_raw.csv"
        var csv = "SensorTime,RawAccelX,RawAccelY,RawAccelZ,RawAccelMag\n"
        let f = { (v: Double) -> String in String(format: "%.4f", v) }
        for dp in event.rawAccelSlice {
            csv += "\(f(dp.sensorTime)),\(f(dp.rawAccelX)),\(f(dp.rawAccelY)),\(f(dp.rawAccelZ)),\(f(dp.rawAccelMag))\n"
        }
        guard let csvData = csv.data(using: .utf8) else { return }
        sendAuthed(
            urlString: "\(projectURL)/storage/v1/object/\(storageBucket)/\(storagePath)",
            method: "POST",
            contentType: "text/csv",
            body: csvData,
            token: token,
            event: event,
            tag: "rawAccelCSV(\(event.rawAccelSlice.count) samples)"
        )
    }

    /// Shared HTTP helper. On 401, refreshes the session once and retries.
    /// `apikey` header is the project-level anon key (Supabase requires it on every
    /// PostgREST/Storage call); `Authorization` is the user's JWT (what RLS reads).
    private func sendAuthed(
        urlString: String,
        method: String,
        contentType: String,
        body: Data,
        token: String,
        event: PendingEvent,
        tag: String,
        isRetry: Bool = false
    ) {
        guard let url = URL(string: urlString) else {
            dprint("⌚ [SupabaseUploader] Bad URL: \(urlString)")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                dprint("⌚ [SupabaseUploader] \(tag) network error: \(error.localizedDescription)")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 200 && status < 300 {
                dprint("⌚ [SupabaseUploader] \(tag) uploaded")
                return
            }
            if status == 401 && !isRetry {
                dprint("⌚ [SupabaseUploader] \(tag) got 401, forcing token refresh and retrying")
                WatchAuthSession.shared.forceRefresh { result in
                    switch result {
                    case .success(let newToken):
                        self.sendAuthed(urlString: urlString, method: method, contentType: contentType, body: body, token: newToken, event: event, tag: tag, isRetry: true)
                    case .failure(let err):
                        dprint("⌚ [SupabaseUploader] \(tag) refresh failed: \(err)")
                    }
                }
                return
            }
            let bodyStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no body"
            dprint("⌚ [SupabaseUploader] \(tag) HTTP \(status): \(bodyStr)")
        }.resume()
    }
}
