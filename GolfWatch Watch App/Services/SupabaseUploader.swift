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

    private func motionStoragePath(eventId: UUID, userId: String) -> String {
        "\(userId)/\(eventId.uuidString).csv"
    }

    private func rawAccelStoragePath(eventId: UUID, userId: String) -> String {
        "\(userId)/\(eventId.uuidString)_raw.csv"
    }

    // MARK: - Event Lifecycle

    /// Called from `fireSmartDetection` on every detection.
    /// In auto-add mode: immediately uploads as positive/low and returns the
    /// event id so the UI can mark it false_positive later via `markFalsePositive`
    /// if the user undoes the auto-added stroke.
    /// In manual mode: flushes any previous pending and holds this one as
    /// pending, awaiting an `onSwingAccepted`/`onSwingRejected` from the popup.
    @discardableResult
    func onSwingDetected(
        metadata: SwingDetectionManager.DetectionMetadata,
        motionSlice: [SwingDetectionManager.RecordedDataPoint],
        rawAccelSlice: [SwingDetectionManager.RawAccelDataPoint] = [],
        clubType: String?,
        autoAdd: Bool
    ) -> UUID? {
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
            // Flush any stale manual pending too
            if let prev = pending { upload(event: prev) }
            pending = nil
            return event.id
        }

        if autoAdd {
            // Auto-add: no popup, no pending — upload immediately as
            // positive/low. Undo path edits the row to false_positive/high.
            // Flush any stale manual pending first (shouldn't happen but
            // defensive).
            if let prev = pending {
                upload(event: prev)
                pending = nil
            }
            let event = PendingEvent(
                id: UUID(),
                metadata: metadata,
                motionSlice: motionSlice,
                rawAccelSlice: rawAccelSlice,
                clubType: clubType,
                label: "positive",
                confidence: "low"
            )
            upload(event: event)
            return event.id
        }

        // Manual mode: flush previous pending (implicit — user didn't act),
        // hold this one for the popup to accept/reject.
        if let prev = pending {
            upload(event: prev)
        }
        pending = PendingEvent(
            id: UUID(),
            metadata: metadata,
            motionSlice: motionSlice,
            rawAccelSlice: rawAccelSlice,
            clubType: clubType,
            label: "false_positive",
            confidence: "low"
        )
        return nil
    }

    /// Called when user taps to add the stroke (manual-add mode).
    /// Flips the pending label to positive with high confidence.
    func onSwingAccepted() {
        pending?.label = "positive"
        pending?.confidence = "high"
    }

    /// Called when user explicitly rejects the manual-add popup with X.
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

    /// Edit a previously uploaded swing_event row to label=false_positive,
    /// confidence=high. Used by the main-screen undo button when the user
    /// undoes an auto-added stroke (the row was uploaded as positive/low at
    /// detection time; undo flips it to high-confidence false_positive).
    func markFalsePositive(eventId: UUID) {
        struct UpdateRow: Encodable {
            let label: String
            let confidence: String
        }
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.supabase
                    .from("swing_events")
                    .update(UpdateRow(label: "false_positive", confidence: "high"))
                    .eq("id", value: eventId.uuidString)
                    .execute()
                ClientEventLogger.log("swing.update.falsePositive.ok", detail: [
                    "eventId": .string(eventId.uuidString)
                ])
            } catch {
                ClientEventLogger.log("swing.update.falsePositive.failed", detail: [
                    "eventId": .string(eventId.uuidString),
                    "error": .string("\(error)")
                ])
            }
        }
    }

    /// Upload a rejected shape as a false-negative training sample. Called
    /// when the user manually adds a stroke and there's a recently-rejected
    /// shape in the buffer (claimed via
    /// `SwingDetectionManager.claimMostRecentRejection`). Captures the
    /// detector's view of the swing PLUS which gate(s) rejected it (in
    /// `event.metadata`), so the labeled sample tells us not just "this was
    /// a real swing the detector missed" but "this was a real swing that
    /// gate X rejected."
    /// Upload an entire group of rejected shapes captured between the
    /// previous successful stroke and a manual stroke add. NOT swing_events
    /// — these are CANDIDATES for a single missed swing; only ONE of the N
    /// rejections corresponds to the real false-negative, the rest are
    /// noise. They go to `false_negative_groups` + `false_negative_candidates`
    /// for later manual sifting.
    func uploadFalseNegativeGroup(
        rejections: [SwingDetectionManager.RejectedShape],
        roundId: UUID?,
        strokeId: UUID?,
        holeNumber: Int?,
        clubType: String?
    ) {
        guard !rejections.isEmpty else { return }
        guard let userId = WatchAuthSession.shared.currentUserId else {
            ClientEventLogger.log("falseNeg.upload.bail.noAuth", detail: [
                "candidateCount": .integer(rejections.count)
            ])
            return
        }
        let groupId = UUID()
        ClientEventLogger.log("falseNeg.upload.start", detail: [
            "groupId": .string(groupId.uuidString),
            "candidateCount": .integer(rejections.count),
            "strokeId": strokeId.map { .string($0.uuidString) } ?? .null
        ])
        Task { [weak self] in
            await self?.insertFalseNegativeGroup(
                groupId: groupId, userId: userId,
                roundId: roundId, strokeId: strokeId,
                holeNumber: holeNumber, candidateCount: rejections.count
            )
            for (index, rejected) in rejections.enumerated() {
                await self?.insertFalseNegativeCandidate(
                    groupId: groupId, userId: userId,
                    position: index, rejected: rejected, clubType: clubType
                )
                await self?.uploadFalseNegativeCSV(
                    groupId: groupId, userId: userId, position: index, rejected: rejected
                )
            }
        }
    }

    private struct FalseNegativeGroupRow: Encodable {
        let id: String
        let user_id: String
        let round_id: String?
        let stroke_id: String?
        let hole_number: Int?
        let candidate_count: Int
    }

    private func insertFalseNegativeGroup(
        groupId: UUID, userId: String,
        roundId: UUID?, strokeId: UUID?,
        holeNumber: Int?, candidateCount: Int
    ) async {
        let row = FalseNegativeGroupRow(
            id: groupId.uuidString,
            user_id: userId,
            round_id: roundId?.uuidString,
            stroke_id: strokeId?.uuidString,
            hole_number: holeNumber,
            candidate_count: candidateCount
        )
        do {
            try await supabase.from("false_negative_groups").insert(row).execute()
            ClientEventLogger.log("falseNeg.group.inserted", detail: [
                "groupId": .string(groupId.uuidString)
            ])
        } catch {
            ClientEventLogger.log("falseNeg.group.failed", detail: [
                "error": .string("\(error)")
            ])
        }
    }

    private struct FalseNegativeCandidateRow: Encodable {
        let group_id: String
        let user_id: String
        let position_in_group: Int
        let rejected_at: Date
        let stage: String
        let gate_fails: String
        let classification: String?
        let swing_type: String?
        let fs_peak_rot_mag: Double?
        let bs_peak_rot_mag: Double?
        let fs_bs_ratio: Double?
        let contact_tv: Double?
        let contact_n: Int?
        let extrema_spread: Double?
        let baseline_tv: Double?
        let setup_duration: Double?
        let bs_to_fs_gap: Double?
        let club_type: String?
        let detection_mode: String?
        let storage_path: String?
    }

    private func insertFalseNegativeCandidate(
        groupId: UUID, userId: String, position: Int,
        rejected: SwingDetectionManager.RejectedShape, clubType: String?
    ) async {
        let shape = rejected.shape
        let gate = rejected.gate
        let bsRotMag = sqrt(
            shape.bsPeakRotX * shape.bsPeakRotX +
            shape.bsPeakRotY * shape.bsPeakRotY +
            shape.bsPeakRotZ * shape.bsPeakRotZ
        )
        let fsBsRatio = bsRotMag > 0.0001 ? shape.fsPeakRotMag / bsRotMag : nil
        let storagePath = "\(userId)/false_negatives/\(groupId.uuidString)/\(position).csv"
        let row = FalseNegativeCandidateRow(
            group_id: groupId.uuidString,
            user_id: userId,
            position_in_group: position,
            rejected_at: rejected.rejectedAt,
            stage: rejected.stage,
            gate_fails: gate.fails.joined(separator: ","),
            classification: shape.classification.rawValue,
            swing_type: shape.classification.rawValue,
            fs_peak_rot_mag: shape.fsPeakRotMag,
            bs_peak_rot_mag: bsRotMag,
            fs_bs_ratio: fsBsRatio,
            contact_tv: gate.contactTV,
            contact_n: gate.contactN,
            extrema_spread: gate.extremaSpread,
            baseline_tv: gate.baselineTV,
            setup_duration: shape.setupEndT - shape.setupStartT,
            bs_to_fs_gap: shape.fsPeakT - shape.bsTopT,
            club_type: clubType,
            detection_mode: "unifDetect",
            storage_path: storagePath
        )
        do {
            try await supabase.from("false_negative_candidates").insert(row).execute()
        } catch {
            ClientEventLogger.log("falseNeg.candidate.failed", detail: [
                "groupId": .string(groupId.uuidString),
                "position": .integer(position),
                "error": .string("\(error)")
            ])
        }
    }

    private func uploadFalseNegativeCSV(
        groupId: UUID, userId: String, position: Int,
        rejected: SwingDetectionManager.RejectedShape
    ) async {
        guard !rejected.motionSlice.isEmpty else { return }
        let storagePath = "\(userId)/false_negatives/\(groupId.uuidString)/\(position).csv"
        var csv = "SensorTime,UserAccelX,UserAccelY,UserAccelZ,UserAccelMag,RotationX,RotationY,RotationZ,RotationMag,GravityX,GravityY,GravityZ,Pitch,Roll,Yaw,MagAccuracy\n"
        let f = { (v: Double) -> String in String(format: "%.4f", v) }
        for dp in rejected.motionSlice {
            csv += "\(f(dp.sensorTime)),\(f(dp.userAccelX)),\(f(dp.userAccelY)),\(f(dp.userAccelZ)),\(f(dp.userAccelMag)),\(f(dp.rotationX)),\(f(dp.rotationY)),\(f(dp.rotationZ)),\(f(dp.rotationMag)),\(f(dp.gravityX)),\(f(dp.gravityY)),\(f(dp.gravityZ)),\(f(dp.pitch)),\(f(dp.roll)),\(f(dp.yaw)),\(dp.magAccuracy)\n"
        }
        guard let csvData = csv.data(using: .utf8) else { return }
        do {
            _ = try await supabase.storage
                .from(storageBucket)
                .upload(storagePath, data: csvData, options: FileOptions(contentType: "text/csv"))
        } catch {
            ClientEventLogger.log("falseNeg.csv.failed", detail: [
                "storagePath": .string(storagePath),
                "error": .string("\(error)")
            ])
        }
    }


    // MARK: - Upload

    private func upload(event: PendingEvent) {
        let eventCopy = event
        guard let userId = WatchAuthSession.shared.currentUserId else {
            ClientEventLogger.log("swing.upload.bail.noAuth", detail: [
                "eventId": .string(eventCopy.id.uuidString),
                "label": .string(eventCopy.label),
                "confidence": .string(eventCopy.confidence)
            ])
            dprint("⌚ [SupabaseUploader] Drop event \(eventCopy.id.uuidString) — not signed in")
            return
        }
        ClientEventLogger.log("swing.upload.start", detail: [
            "eventId": .string(eventCopy.id.uuidString),
            "label": .string(eventCopy.label),
            "confidence": .string(eventCopy.confidence),
            "motionSampleCount": .integer(eventCopy.motionSlice.count),
            "rawAccelSampleCount": .integer(eventCopy.rawAccelSlice.count)
        ])
        Task { [weak self] in
            guard let self = self else { return }
            let storagePath = await self.uploadMotionCSV(event: eventCopy, userId: userId)
            await self.uploadMetadata(event: eventCopy, userId: userId, storagePath: storagePath)
            await self.uploadRawAccelCSV(event: eventCopy, userId: userId)
        }
    }

    /// SDK SwingEvent payload — intentionally a separate Codable shape so we
    /// don't accidentally couple it to anything else.
    private struct SwingEventRow: Encodable {
        let id: String
        let classification: String
        let swing_type: String
        let label: String?
        let confidence: String?
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
        let storage_path: String?
    }

    private func uploadMetadata(event: PendingEvent, userId: String, storagePath: String?) async {
        let meta = event.metadata
        let rowLabel = storagePath != nil ? event.label : nil
        let rowConfidence = storagePath != nil ? event.confidence : nil
        let row = SwingEventRow(
            id: event.id.uuidString,
            classification: event.clubType ?? "unknown",
            swing_type: event.clubType ?? "unknown",
            label: rowLabel,
            confidence: rowConfidence,
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
            ClientEventLogger.log("swing.upload.metadata.ok", detail: [
                "eventId": .string(event.id.uuidString),
                "storagePath": storagePath != nil ? .string(storagePath!) : .null,
                "label": rowLabel != nil ? .string(rowLabel!) : .null,
                "confidence": rowConfidence != nil ? .string(rowConfidence!) : .null
            ])
            dprint("⌚ [SupabaseUploader] metadata(\(event.label)/\(event.confidence)) uploaded")
        } catch {
            ClientEventLogger.log("swing.upload.metadata.failed", detail: [
                "eventId": .string(event.id.uuidString),
                "storagePath": storagePath != nil ? .string(storagePath!) : .null,
                "label": rowLabel != nil ? .string(rowLabel!) : .null,
                "confidence": rowConfidence != nil ? .string(rowConfidence!) : .null,
                "error": .string("\(error)")
            ])
            dprint("⌚ [SupabaseUploader] metadata upload failed: \(error)")
        }
    }

    private func uploadMotionCSV(event: PendingEvent, userId: String) async -> String? {
        guard !event.motionSlice.isEmpty else {
            ClientEventLogger.log("swing.upload.bail.noMotion", detail: [
                "eventId": .string(event.id.uuidString),
                "label": .string(event.label),
                "confidence": .string(event.confidence),
                "motionSampleCount": .integer(event.motionSlice.count),
                "rawAccelSampleCount": .integer(event.rawAccelSlice.count)
            ])
            dprint("⌚ [SupabaseUploader] No motion data to upload for \(event.id.uuidString)")
            return nil
        }
        let storagePath = motionStoragePath(eventId: event.id, userId: userId)
        var csv = "SensorTime,UserAccelX,UserAccelY,UserAccelZ,UserAccelMag,RotationX,RotationY,RotationZ,RotationMag,GravityX,GravityY,GravityZ,Pitch,Roll,Yaw,MagAccuracy\n"
        let f = { (v: Double) -> String in String(format: "%.4f", v) }
        for dp in event.motionSlice {
            csv += "\(f(dp.sensorTime)),\(f(dp.userAccelX)),\(f(dp.userAccelY)),\(f(dp.userAccelZ)),\(f(dp.userAccelMag)),\(f(dp.rotationX)),\(f(dp.rotationY)),\(f(dp.rotationZ)),\(f(dp.rotationMag)),\(f(dp.gravityX)),\(f(dp.gravityY)),\(f(dp.gravityZ)),\(f(dp.pitch)),\(f(dp.roll)),\(f(dp.yaw)),\(dp.magAccuracy)\n"
        }
        guard let csvData = csv.data(using: .utf8) else {
            ClientEventLogger.log("swing.upload.bail.noMotion", detail: [
                "eventId": .string(event.id.uuidString),
                "label": .string(event.label),
                "confidence": .string(event.confidence),
                "motionSampleCount": .integer(event.motionSlice.count),
                "rawAccelSampleCount": .integer(event.rawAccelSlice.count)
            ])
            dprint("⌚ [SupabaseUploader] Failed to encode motion CSV for \(event.id.uuidString)")
            return nil
        }
        do {
            _ = try await supabase.storage
                .from(storageBucket)
                .upload(storagePath, data: csvData, options: FileOptions(contentType: "text/csv"))
            ClientEventLogger.log("swing.upload.motion.ok", detail: [
                "eventId": .string(event.id.uuidString),
                "storagePath": .string(storagePath),
                "sampleCount": .integer(event.motionSlice.count)
            ])
            dprint("⌚ [SupabaseUploader] motionCSV(\(event.motionSlice.count) samples) uploaded")
            return storagePath
        } catch {
            ClientEventLogger.log("swing.upload.motion.failed", detail: [
                "eventId": .string(event.id.uuidString),
                "storagePath": .string(storagePath),
                "motionSampleCount": .integer(event.motionSlice.count),
                "error": .string("\(error)")
            ])
            dprint("⌚ [SupabaseUploader] motionCSV upload failed: \(error)")
            return nil
        }
    }

    private func uploadRawAccelCSV(event: PendingEvent, userId: String) async {
        guard !event.rawAccelSlice.isEmpty else { return }
        let storagePath = rawAccelStoragePath(eventId: event.id, userId: userId)
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
            ClientEventLogger.log("swing.upload.raw.ok", detail: [
                "eventId": .string(event.id.uuidString),
                "storagePath": .string(storagePath),
                "sampleCount": .integer(event.rawAccelSlice.count)
            ])
            dprint("⌚ [SupabaseUploader] rawAccelCSV(\(event.rawAccelSlice.count) samples) uploaded")
        } catch {
            ClientEventLogger.log("swing.upload.raw.failed", detail: [
                "eventId": .string(event.id.uuidString),
                "storagePath": .string(storagePath),
                "error": .string("\(error)")
            ])
            dprint("⌚ [SupabaseUploader] rawAccelCSV upload failed: \(error)")
        }
    }
}
