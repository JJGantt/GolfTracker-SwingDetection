import Foundation
import Supabase

/// Uploads swing detection events to Supabase for ML analysis.
/// Manages the pending-event lifecycle: each detection is held until
/// explicitly accepted/rejected or flushed by the next detection.
class SupabaseUploader {
    static let shared = SupabaseUploader()

    // MARK: - Configuration

    private let supabase = SupabaseManager.shared
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
        guard let userId = WatchAuthSession.shared.currentUserId else {
            dprint("⌚ [SupabaseUploader] Drop event \(eventCopy.id.uuidString) — not signed in")
            return
        }
        Task { [weak self] in
            await self?.uploadMetadata(event: eventCopy, userId: userId)
            await self?.uploadMotionCSV(event: eventCopy, userId: userId)
            await self?.uploadRawAccelCSV(event: eventCopy, userId: userId)
        }
    }

    /// SDK SwingEvent payload — intentionally a separate Codable shape so we
    /// don't accidentally couple it to anything else.
    private struct SwingEventRow: Encodable {
        let id: String
        let classification: String
        let swing_type: String
        let label: String
        let confidence: String
        let fs_peak_rot_mag: Double?
        let bs_peak_rot_mag: Double?
        let fs_bs_ratio: Double?
        let peak_acceleration: Double?
        let contact_tv: Double?
        let contact_n: Int?
        let extrema_spread: Double?
        let baseline_tv: Double?
        let setup_duration: Double?
        let bs_to_fs_gap: Double
        let club_type: String?
        let detection_mode: String
        let storage_path: String
    }

    private func uploadMetadata(event: PendingEvent, userId: String) async {
        let meta = event.metadata
        let storagePath = "\(userId)/\(event.id.uuidString).csv"
        let row = SwingEventRow(
            id: event.id.uuidString,
            classification: event.clubType ?? "unknown",
            swing_type: event.clubType ?? "unknown",
            label: event.label,
            confidence: event.confidence,
            fs_peak_rot_mag: meta.fsPeakRotMag,
            bs_peak_rot_mag: meta.bsRotMag,
            fs_bs_ratio: meta.fsBsRatio,
            peak_acceleration: meta.peakAcceleration,
            contact_tv: meta.contactTV,
            contact_n: meta.contactN,
            extrema_spread: meta.extremaSpread,
            baseline_tv: meta.baselineTV,
            setup_duration: meta.setupDuration,
            bs_to_fs_gap: meta.fsPeakT - meta.bsTopT,
            club_type: event.clubType,
            detection_mode: "unifDetect",
            storage_path: storagePath
        )
        do {
            try await supabase.from("swing_events").insert(row).execute()
            dprint("⌚ [SupabaseUploader] metadata(\(event.label)/\(event.confidence)) uploaded")
        } catch {
            dprint("⌚ [SupabaseUploader] metadata upload failed: \(error)")
        }
    }

    private func uploadMotionCSV(event: PendingEvent, userId: String) async {
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
        do {
            _ = try await supabase.storage
                .from(storageBucket)
                .upload(storagePath, data: csvData, options: FileOptions(contentType: "text/csv"))
            dprint("⌚ [SupabaseUploader] motionCSV(\(event.motionSlice.count) samples) uploaded")
        } catch {
            dprint("⌚ [SupabaseUploader] motionCSV upload failed: \(error)")
        }
    }

    private func uploadRawAccelCSV(event: PendingEvent, userId: String) async {
        guard !event.rawAccelSlice.isEmpty else { return }
        let storagePath = "\(userId)/\(event.id.uuidString)_raw.csv"
        var csv = "SensorTime,RawAccelX,RawAccelY,RawAccelZ,RawAccelMag\n"
        let f = { (v: Double) -> String in String(format: "%.4f", v) }
        for dp in event.rawAccelSlice {
            csv += "\(f(dp.sensorTime)),\(f(dp.rawAccelX)),\(f(dp.rawAccelY)),\(f(dp.rawAccelZ)),\(f(dp.rawAccelMag))\n"
        }
        guard let csvData = csv.data(using: .utf8) else { return }
        do {
            _ = try await supabase.storage
                .from(storageBucket)
                .upload(storagePath, data: csvData, options: FileOptions(contentType: "text/csv"))
            dprint("⌚ [SupabaseUploader] rawAccelCSV(\(event.rawAccelSlice.count) samples) uploaded")
        } catch {
            dprint("⌚ [SupabaseUploader] rawAccelCSV upload failed: \(error)")
        }
    }
}
