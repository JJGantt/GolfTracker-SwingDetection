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

    /// Non-nil while Swing Test Mode is running. Stamped onto every event
    /// constructed for its lifetime so test detections stay filterable from
    /// round play without a parallel schema. Set by `SwingTestSession.start`,
    /// cleared on stop — reading it here rather than threading it through
    /// `fireSmartDetection` keeps the detector unaware that test mode exists.
    var currentTestSessionId: UUID?

    // MARK: - Pending Event

    struct PendingEvent {
        let id: UUID
        let metadata: SwingDetectionManager.DetectionMetadata
        let motionSlice: [SwingDetectionManager.RecordedDataPoint]
        let rawAccelSlice: [SwingDetectionManager.RawAccelDataPoint]
        let clubType: String?
        var label: String       // "positive" or "false_positive"
        var confidence: String  // "high" or "low"
        var testSessionId: UUID?
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
                confidence: "high",
                testSessionId: currentTestSessionId
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
                confidence: "low",
                testSessionId: currentTestSessionId
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
            confidence: "low",
            testSessionId: currentTestSessionId
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

    /// Mark a correctly-detected swing that did not become a counted stroke.
    ///
    /// Used by the practice-swing replacement path, which drops the previous
    /// auto-added stroke when the user swings twice in the same spot without
    /// walking. That used to call `markFalsePositive`, which was backwards:
    /// `label` states whether the DETECTOR was right, and on a practice swing
    /// it was — real swing motion, correctly identified. It just wasn't a shot.
    ///
    /// The distinction is not cosmetic. The replacement heuristic fires only on
    /// an unambiguous, attended, repeated swing, which makes it the strongest
    /// true-positive evidence the app generates; labeling it `false_positive`
    /// took the best positive samples available and trained against them.
    /// `label=positive/high` records the detection was right, and
    /// `not_a_stroke_reason` records why it wasn't counted.
    func markPracticeSwing(eventId: UUID) {
        struct UpdateRow: Encodable {
            let label: String
            let confidence: String
            let not_a_stroke_reason: String
        }
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.supabase
                    .from("swing_events")
                    .update(UpdateRow(label: "positive", confidence: "high",
                                      not_a_stroke_reason: "practice"))
                    .eq("id", value: eventId.uuidString)
                    .execute()
                ClientEventLogger.log("swing.update.practice.ok", detail: [
                    "eventId": .string(eventId.uuidString)
                ])
            } catch {
                ClientEventLogger.log("swing.update.practice.failed", detail: [
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
            guard let self else { return }
            // Candidates FK-reference the group row; without it they'd all
            // fail anyway, so bail on the whole batch.
            guard await self.insertFalseNegativeGroup(
                groupId: groupId, userId: userId,
                roundId: roundId, strokeId: strokeId,
                holeNumber: holeNumber, candidateCount: rejections.count
            ) else { return }
            for (index, rejected) in rejections.enumerated() {
                // Skip the CSV when its DB row didn't land — orphaned
                // Storage objects are invisible to the labeling pipeline.
                let inserted = await self.insertFalseNegativeCandidate(
                    groupId: groupId, userId: userId,
                    position: index, rejected: rejected, clubType: clubType
                )
                if inserted {
                    await self.uploadFalseNegativeCSV(
                        groupId: groupId, userId: userId, position: index, rejected: rejected
                    )
                }
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
        let capture_reason: String
        let storage_path: String?
        let test_session_id: String?
        let window_seconds: Double?
    }

    private func insertFalseNegativeGroup(
        groupId: UUID, userId: String,
        roundId: UUID?, strokeId: UUID?,
        holeNumber: Int?, candidateCount: Int,
        captureReason: String = "rejected_shapes",
        storagePath: String? = nil,
        testSessionId: UUID? = nil,
        windowSeconds: Double? = nil
    ) async -> Bool {
        let row = FalseNegativeGroupRow(
            id: groupId.uuidString,
            user_id: userId,
            round_id: roundId?.uuidString,
            stroke_id: strokeId?.uuidString,
            hole_number: holeNumber,
            candidate_count: candidateCount,
            capture_reason: captureReason,
            storage_path: storagePath,
            test_session_id: testSessionId?.uuidString,
            window_seconds: windowSeconds
        )
        do {
            try await supabase.from("false_negative_groups").insert(row).execute()
            ClientEventLogger.log("falseNeg.group.inserted", detail: [
                "groupId": .string(groupId.uuidString)
            ])
            return true
        } catch {
            ClientEventLogger.log("falseNeg.group.failed", detail: [
                "error": .string("\(error)")
            ])
            return false
        }
    }

    // MARK: - Lookback Capture ("Missed It")

    /// Upload a raw motion window for a swing the detector gave no sign of.
    ///
    /// `uploadFalseNegativeGroup` can only describe a miss the detector ALMOST
    /// caught, because `recordRejection` is reachable only from the
    /// post-pairing gates — setup, backswing top and follow-through peak all
    /// paired, then a contact gate killed it. A swing that fails earlier (no
    /// setup event, no valley or peak clearing prominence, pairing blocked by
    /// an intervening event) produces no rejection at all, so the manual-add
    /// path finds an empty buffer and uploads nothing. The miss that is
    /// hardest to reconstruct afterwards was the one generating no data.
    ///
    /// This is the escape hatch: dump the raw rolling buffer for the window
    /// the user just swung in. Any rejections that fall INSIDE that window ride
    /// along as candidates — the buffer is maintained regardless, so attaching
    /// them costs nothing and answers "which gate killed it" alongside the raw
    /// "what did my arm actually do". A candidate count of zero is not a failed
    /// capture; it is the finding, and it means nothing paired.
    func uploadLookbackCapture(
        motionSlice: [SwingDetectionManager.RecordedDataPoint],
        rawAccelSlice: [SwingDetectionManager.RawAccelDataPoint],
        rejections: [SwingDetectionManager.RejectedShape],
        windowSeconds: Double,
        roundId: UUID?,
        holeNumber: Int?,
        clubType: String?,
        testSessionId: UUID?
    ) {
        guard !motionSlice.isEmpty else {
            ClientEventLogger.log("lookback.upload.bail.noMotion")
            return
        }
        guard let userId = WatchAuthSession.shared.currentUserId else {
            ClientEventLogger.log("lookback.upload.bail.noAuth", detail: [
                "sampleCount": .integer(motionSlice.count)
            ])
            return
        }
        let groupId = UUID()
        let storagePath = "\(userId)/lookback/\(groupId.uuidString)/window.csv"
        ClientEventLogger.log("lookback.upload.start", detail: [
            "groupId": .string(groupId.uuidString),
            "sampleCount": .integer(motionSlice.count),
            "rawAccelCount": .integer(rawAccelSlice.count),
            "candidateCount": .integer(rejections.count),
            "windowSeconds": .double(windowSeconds)
        ])
        Task { [weak self] in
            guard let self else { return }
            guard await self.insertFalseNegativeGroup(
                groupId: groupId, userId: userId,
                roundId: roundId, strokeId: nil,
                holeNumber: holeNumber, candidateCount: rejections.count,
                captureReason: "lookback", storagePath: storagePath,
                testSessionId: testSessionId, windowSeconds: windowSeconds
            ) else { return }

            await self.uploadLookbackCSV(
                storagePath: storagePath, motionSlice: motionSlice
            )
            if !rawAccelSlice.isEmpty {
                await self.uploadLookbackRawCSV(
                    storagePath: "\(userId)/lookback/\(groupId.uuidString)/window_raw.csv",
                    rawAccelSlice: rawAccelSlice
                )
            }
            // Rejections inside the window, as ordinary candidates — same
            // schema and same downstream tooling as a manual-add group.
            for (index, rejected) in rejections.enumerated() {
                let inserted = await self.insertFalseNegativeCandidate(
                    groupId: groupId, userId: userId,
                    position: index, rejected: rejected, clubType: clubType
                )
                if inserted {
                    await self.uploadFalseNegativeCSV(
                        groupId: groupId, userId: userId, position: index, rejected: rejected
                    )
                }
            }
            ClientEventLogger.log("lookback.upload.done", detail: [
                "groupId": .string(groupId.uuidString)
            ])
        }
    }

    private func uploadLookbackCSV(
        storagePath: String, motionSlice: [SwingDetectionManager.RecordedDataPoint]
    ) async {
        var csv = "SensorTime,UserAccelX,UserAccelY,UserAccelZ,UserAccelMag,RotationX,RotationY,RotationZ,RotationMag,GravityX,GravityY,GravityZ,Pitch,Roll,Yaw,MagAccuracy\n"
        let f = { (v: Double) -> String in String(format: "%.4f", v) }
        for dp in motionSlice {
            csv += "\(f(dp.sensorTime)),\(f(dp.userAccelX)),\(f(dp.userAccelY)),\(f(dp.userAccelZ)),\(f(dp.userAccelMag)),\(f(dp.rotationX)),\(f(dp.rotationY)),\(f(dp.rotationZ)),\(f(dp.rotationMag)),\(f(dp.gravityX)),\(f(dp.gravityY)),\(f(dp.gravityZ)),\(f(dp.pitch)),\(f(dp.roll)),\(f(dp.yaw)),\(dp.magAccuracy)\n"
        }
        guard let data = csv.data(using: .utf8) else {
            ClientEventLogger.log("lookback.csv.encodeFailed", detail: [
                "storagePath": .string(storagePath)
            ])
            return
        }
        do {
            _ = try await supabase.storage
                .from(storageBucket)
                .upload(storagePath, data: data, options: FileOptions(contentType: "text/csv"))
            ClientEventLogger.log("lookback.csv.ok", detail: [
                "storagePath": .string(storagePath),
                "sampleCount": .integer(motionSlice.count)
            ])
        } catch {
            ClientEventLogger.log("lookback.csv.failed", detail: [
                "storagePath": .string(storagePath),
                "error": .string("\(error)")
            ])
        }
    }

    private func uploadLookbackRawCSV(
        storagePath: String, rawAccelSlice: [SwingDetectionManager.RawAccelDataPoint]
    ) async {
        var csv = "SensorTime,RawAccelX,RawAccelY,RawAccelZ,RawAccelMag\n"
        let f = { (v: Double) -> String in String(format: "%.4f", v) }
        for dp in rawAccelSlice {
            csv += "\(f(dp.sensorTime)),\(f(dp.rawAccelX)),\(f(dp.rawAccelY)),\(f(dp.rawAccelZ)),\(f(dp.rawAccelMag))\n"
        }
        guard let data = csv.data(using: .utf8) else { return }
        do {
            _ = try await supabase.storage
                .from(storageBucket)
                .upload(storagePath, data: data, options: FileOptions(contentType: "text/csv"))
            ClientEventLogger.log("lookback.rawCsv.ok", detail: [
                "storagePath": .string(storagePath),
                "sampleCount": .integer(rawAccelSlice.count)
            ])
        } catch {
            ClientEventLogger.log("lookback.rawCsv.failed", detail: [
                "storagePath": .string(storagePath),
                "error": .string("\(error)")
            ])
        }
    }

    // MARK: - Test Sessions

    private struct TestSessionRow: Encodable {
        let id: String
        let user_id: String
        let detection_mode: String
    }

    private struct TestSessionEndRow: Encodable {
        let ended_at: String
        let detected_count: Int
        let false_positive_count: Int
        let lookback_count: Int
    }

    /// Insert the session row. Best-effort: `swing_events.test_session_id` is a
    /// soft reference (matching the `stroke_id` precedent in 00030), so a
    /// detection in the first moments of a session is never lost to a session
    /// row that hasn't landed yet.
    func createTestSession(id: UUID) {
        guard let userId = WatchAuthSession.shared.currentUserId else {
            ClientEventLogger.log("swingTest.session.bail.noAuth")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.supabase.from("swing_test_sessions")
                    .insert(TestSessionRow(id: id.uuidString, user_id: userId,
                                           detection_mode: "unifDetect"))
                    .execute()
                ClientEventLogger.log("swingTest.session.created", detail: [
                    "sessionId": .string(id.uuidString)
                ])
            } catch {
                ClientEventLogger.log("swingTest.session.failed", detail: [
                    "sessionId": .string(id.uuidString),
                    "error": .string("\(error)")
                ])
            }
        }
    }

    /// Close the session and store the counters the watch actually displayed,
    /// so a session can be checked against its rows without assuming every
    /// upload landed.
    func endTestSession(id: UUID, detected: Int, falsePositives: Int, lookbacks: Int) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.supabase.from("swing_test_sessions")
                    .update(TestSessionEndRow(
                        ended_at: ISO8601DateFormatter().string(from: Date()),
                        detected_count: detected,
                        false_positive_count: falsePositives,
                        lookback_count: lookbacks
                    ))
                    .eq("id", value: id.uuidString)
                    .execute()
                ClientEventLogger.log("swingTest.session.ended", detail: [
                    "sessionId": .string(id.uuidString),
                    "detected": .integer(detected),
                    "falsePositives": .integer(falsePositives),
                    "lookbacks": .integer(lookbacks)
                ])
            } catch {
                ClientEventLogger.log("swingTest.session.end.failed", detail: [
                    "sessionId": .string(id.uuidString),
                    "error": .string("\(error)")
                ])
            }
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
    ) async -> Bool {
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
            return true
        } catch {
            ClientEventLogger.log("falseNeg.candidate.failed", detail: [
                "groupId": .string(groupId.uuidString),
                "position": .integer(position),
                "error": .string("\(error)")
            ])
            return false
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
        guard let csvData = csv.data(using: .utf8) else {
            ClientEventLogger.log("falseNeg.csv.encodeFailed", detail: [
                "storagePath": .string(storagePath)
            ])
            return
        }
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
            let metadataOK = await self.uploadMetadata(event: eventCopy, userId: userId, storagePath: storagePath)
            // Don't upload the raw CSV if its DB row never landed — that
            // leaves orphaned Storage objects with no swing_events row.
            if metadataOK {
                await self.uploadRawAccelCSV(event: eventCopy, userId: userId)
            }
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
        let test_session_id: String?
    }

    @discardableResult
    private func uploadMetadata(event: PendingEvent, userId: String, storagePath: String?) async -> Bool {
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
            storage_path: storagePath,
            test_session_id: event.testSessionId?.uuidString
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
            return true
        } catch {
            ClientEventLogger.log("swing.upload.metadata.failed", detail: [
                "eventId": .string(event.id.uuidString),
                "storagePath": storagePath != nil ? .string(storagePath!) : .null,
                "label": rowLabel != nil ? .string(rowLabel!) : .null,
                "confidence": rowConfidence != nil ? .string(rowConfidence!) : .null,
                "error": .string("\(error)")
            ])
            dprint("⌚ [SupabaseUploader] metadata upload failed: \(error)")
            return false
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
        guard let csvData = csv.data(using: .utf8) else {
            ClientEventLogger.log("swing.upload.raw.encodeFailed", detail: [
                "eventId": .string(event.id.uuidString)
            ])
            return
        }
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
