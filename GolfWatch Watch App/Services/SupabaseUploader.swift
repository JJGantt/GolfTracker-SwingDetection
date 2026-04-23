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

    /// Stable per-install device ID. Generated once, persisted in UserDefaults.
    private(set) lazy var deviceId: UUID = {
        if let stored = UserDefaults.standard.string(forKey: "supabaseDeviceId"),
           let uuid = UUID(uuidString: stored) {
            return uuid
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: "supabaseDeviceId")
        return id
    }()

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
            self.uploadMetadata(event: eventCopy)
            self.uploadMotionCSV(event: eventCopy)
            self.uploadRawAccelCSV(event: eventCopy)
        }
    }

    private func uploadMetadata(event: PendingEvent) {
        let meta = event.metadata
        let storagePath = "\(deviceId.uuidString)/\(event.id.uuidString).csv"

        let payload: [String: Any?] = [
            "device_id": deviceId.uuidString,
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

        // Remove nil values for JSON serialization
        let cleanPayload = payload.compactMapValues { $0 }

        guard let url = URL(string: "\(projectURL)/rest/v1/swing_events"),
              let body = try? JSONSerialization.data(withJSONObject: cleanPayload) else {
            dprint("⌚ [SupabaseUploader] Failed to build metadata request")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                dprint("⌚ [SupabaseUploader] Metadata upload failed: \(error.localizedDescription)")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 200 && status < 300 {
                dprint("⌚ [SupabaseUploader] Metadata uploaded (\(event.label)/\(event.confidence))")
            } else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no body"
                dprint("⌚ [SupabaseUploader] Metadata upload HTTP \(status): \(body)")
            }
        }.resume()
    }

    private func uploadMotionCSV(event: PendingEvent) {
        guard !event.motionSlice.isEmpty else {
            dprint("⌚ [SupabaseUploader] No motion data to upload")
            return
        }

        let storagePath = "\(deviceId.uuidString)/\(event.id.uuidString).csv"

        // Build CSV
        var csv = "SensorTime,UserAccelX,UserAccelY,UserAccelZ,UserAccelMag,RotationX,RotationY,RotationZ,RotationMag,GravityX,GravityY,GravityZ,Pitch,Roll,Yaw\n"
        let f = { (v: Double) -> String in String(format: "%.4f", v) }
        for dp in event.motionSlice {
            csv += "\(f(dp.sensorTime)),\(f(dp.userAccelX)),\(f(dp.userAccelY)),\(f(dp.userAccelZ)),\(f(dp.userAccelMag)),\(f(dp.rotationX)),\(f(dp.rotationY)),\(f(dp.rotationZ)),\(f(dp.rotationMag)),\(f(dp.gravityX)),\(f(dp.gravityY)),\(f(dp.gravityZ)),\(f(dp.pitch)),\(f(dp.roll)),\(f(dp.yaw))\n"
        }

        guard let csvData = csv.data(using: .utf8),
              let url = URL(string: "\(projectURL)/storage/v1/object/\(storageBucket)/\(storagePath)") else {
            dprint("⌚ [SupabaseUploader] Failed to build storage request")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("text/csv", forHTTPHeaderField: "Content-Type")
        request.httpBody = csvData

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                dprint("⌚ [SupabaseUploader] CSV upload failed: \(error.localizedDescription)")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 200 && status < 300 {
                dprint("⌚ [SupabaseUploader] CSV uploaded (\(event.motionSlice.count) samples)")
            } else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no body"
                dprint("⌚ [SupabaseUploader] CSV upload HTTP \(status): \(body)")
            }
        }.resume()
    }

    private func uploadRawAccelCSV(event: PendingEvent) {
        guard !event.rawAccelSlice.isEmpty else { return }

        let storagePath = "\(deviceId.uuidString)/\(event.id.uuidString)_raw.csv"

        var csv = "SensorTime,RawAccelX,RawAccelY,RawAccelZ,RawAccelMag\n"
        let f = { (v: Double) -> String in String(format: "%.4f", v) }
        for dp in event.rawAccelSlice {
            csv += "\(f(dp.sensorTime)),\(f(dp.rawAccelX)),\(f(dp.rawAccelY)),\(f(dp.rawAccelZ)),\(f(dp.rawAccelMag))\n"
        }

        guard let csvData = csv.data(using: .utf8),
              let url = URL(string: "\(projectURL)/storage/v1/object/\(storageBucket)/\(storagePath)") else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("text/csv", forHTTPHeaderField: "Content-Type")
        request.httpBody = csvData

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                dprint("⌚ [SupabaseUploader] Raw accel upload failed: \(error.localizedDescription)")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 200 && status < 300 {
                dprint("⌚ [SupabaseUploader] Raw accel uploaded (\(event.rawAccelSlice.count) samples)")
            } else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no body"
                dprint("⌚ [SupabaseUploader] Raw accel upload HTTP \(status): \(body)")
            }
        }.resume()
    }
}
