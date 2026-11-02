import Foundation
import os
import CoreLocation
import WatchKit
import StrokeSaverAlgorithms

// A confirmed shape becoming a detection: what it records, what it uploads,
// and the haptic that announces it.
extension SwingDetectionManager {

    struct DetectionMetadata {
        var strokeId: UUID?
        let timestamp: Date
        let swingType: SwingType
        let classification: StrokeClassification

        // Setup
        let setupStartT: TimeInterval
        let setupEndT: TimeInterval
        let setupDuration: TimeInterval

        // BS Top
        let bsTopT: TimeInterval
        let bsClassification: StrokeClassification
        let bsRotMag: Double
        let bsProminence: Double
        let bsPeakRotX, bsPeakRotY, bsPeakRotZ: Double
        let bsTopPitch, bsTopRoll: Double
        let bsAreaBeforeX, bsAreaBeforeY, bsAreaBeforeZ: Double
        let bsAreaAfterX, bsAreaAfterY, bsAreaAfterZ: Double

        // FS Peak
        let fsPeakT: TimeInterval
        let fsClassification: StrokeClassification
        let fsPeakRotMag: Double
        let fsProminence: Double
        let fsPeakRotX, fsPeakRotY, fsPeakRotZ: Double
        let fsAreaBeforeX, fsAreaBeforeY, fsAreaBeforeZ: Double
        let fsAreaAfterX, fsAreaAfterY, fsAreaAfterZ: Double

        // Derived
        let fsBsRatio: Double
        let peakAcceleration: Double
        let preStrokePitch, preStrokeRoll: Double

        // Post-pairing gate values (nil if requirePostPairingGates was off)
        let contactTV: Double?
        let contactN: Int?
        let contactTVX, contactTVY, contactTVZ: Double?
        let extremaSpread: Double?
        let baselineTV: Double?
        let baselineN: Int?

        // Location
        let latitude, longitude: Double
        let trajectoryHeading: Double?
    }

    struct DetectedSwing {
        let location: CLLocationCoordinate2D
        let timestamp: Date
        let peakAcceleration: Double
        let trajectoryHeading: Double?
        let swingType: SwingType
        let fsPeakRotMag: Double
        let fsBsRatio: Double
        let bsTopPitch: Double
        let bsTopRoll: Double
        let preStrokePitch: Double
        let preStrokeRoll: Double
        let bsPeakRotX: Double
        let bsPeakRotY: Double
        let bsPeakRotZ: Double
        let bsPeakRotMag: Double
        let fsPeakRotX: Double
        let fsPeakRotY: Double
        let fsPeakRotZ: Double
    }

    func fireSmartDetection(
        result: SwingDetectionResult,
        shapeEvent: UnifiedShapeEvent? = nil,
        contactTV: Double? = nil,
        contactN: Int? = nil,
        contactTVX: Double? = nil,
        contactTVY: Double? = nil,
        contactTVZ: Double? = nil,
        extremaSpread: Double? = nil,
        baselineTV: Double? = nil,
        baselineN: Int? = nil,
        /// Per-gate value/limit/margin/passed. Recorded on passes too, so a
        /// detection that only just cleared a gate says so on its own row.
        gateReport: [String: [String: Double]]? = nil
    ) {
        // Pedometer counter restarts here so the next inter-swing window
        // measures from this detection forward. Practice-shot dedup later
        // reads stepsSinceLastDetectedSwing at the moment of the next
        // detection.
        DispatchQueue.main.async { self.resetStepsSinceLastDetectedSwing() }

        // Runs on the motion or raw-accel queue: settings come from the
        // lock-backed mirror, read once so the whole detection sees one state.
        let settings = engine
        let location = LocationManager.latestDeviceLocation
        ClientEventLogger.log("swing.fire.enter", detail: [
            "hasLocation": .bool(location != nil),
            "hasShapeEvent": .bool(shapeEvent != nil),
            "selectedClubType": settings.selectedClubTypeName.map { .string($0) } ?? .null,
            "isPutterSelected": .bool(settings.selectedClubTypeName == "Putt"),
            "raw800Running": .bool(settings.isBatchedAccelRunning),
            "workoutSessionState": .string("\(WorkoutManager.currentSessionState.rawValue)")
        ])
        // Position is context for a stroke, not a precondition for detecting a
        // swing — but this used to bail unconditionally without one, which
        // silently discarded the detection AND its motion slice. Swing Test
        // Mode runs with no round and usually indoors, exactly where a fix is
        // least likely, so under the old guard every test detection would have
        // vanished at this line. A test detection has no stroke to place, so it
        // carries an explicitly invalid coordinate rather than a plausible-
        // looking zero.
        let coordinate: CLLocationCoordinate2D
        if let location {
            coordinate = location.coordinate
        } else if settings.testModeActive {
            coordinate = kCLLocationCoordinate2DInvalid
            ClientEventLogger.log("swing.fire.noLocation.testMode")
        } else {
            ClientEventLogger.log("swing.fire.bail.noLocation")
            dprint("⌚ [SwingDetection] Swing detected but no location available")
            return
        }

        // Ball launch bearing from the detector's swing direction. The paired
        // shape's BS-top and FS-peak times ARE the segmentation it needs.
        // Nil for a shape with no buffered window; the stroke-recording paths
        // then record a nil heading. There is deliberately no bearing-to-hole
        // fallback — it produced a number indistinguishable from a real
        // measurement while carrying none of the information.
        let swingHeading = shapeEvent.flatMap { shape in
            withDetector { $0.swingBearing(bsTopT: shape.bsTopT, fsPeakT: shape.fsPeakT) }
        }
        if let h = swingHeading {
            ClientEventLogger.log("swing.direction", detail: [
                "bearing": .double(h),
                "type": .string(result.type.rawValue)
            ])
        }

        let swing = DetectedSwing(
            location: coordinate,
            timestamp: Date(),
            peakAcceleration: result.peakAcceleration,
            trajectoryHeading: swingHeading,
            swingType: result.type,
            fsPeakRotMag: result.fsPeakRotMag,
            fsBsRatio: result.fsBsRatio,
            bsTopPitch: result.bsTopPitch,
            bsTopRoll: result.bsTopRoll,
            preStrokePitch: result.preStrokePitch,
            preStrokeRoll: result.preStrokeRoll,
            bsPeakRotX: result.bsPeakRotX,
            bsPeakRotY: result.bsPeakRotY,
            bsPeakRotZ: result.bsPeakRotZ,
            bsPeakRotMag: result.bsPeakRotMag,
            fsPeakRotX: result.fsPeakRotX,
            fsPeakRotY: result.fsPeakRotY,
            fsPeakRotZ: result.fsPeakRotZ
        )

        // Build detection metadata if shape event is available
        var detectionMeta: DetectionMetadata?
        if let shape = shapeEvent {
            let classification = shape.classification
            let metadata = DetectionMetadata(
                strokeId: nil,
                timestamp: Date(),
                swingType: result.type,
                classification: classification,
                setupStartT: shape.setupStartT,
                setupEndT: shape.setupEndT,
                setupDuration: shape.setupEndT - shape.setupStartT,
                bsTopT: shape.bsTopT,
                bsClassification: shape.bsClassification,
                bsRotMag: result.bsPeakRotMag,
                bsProminence: shape.bsProminence,
                bsPeakRotX: result.bsPeakRotX,
                bsPeakRotY: result.bsPeakRotY,
                bsPeakRotZ: result.bsPeakRotZ,
                bsTopPitch: result.bsTopPitch,
                bsTopRoll: result.bsTopRoll,
                bsAreaBeforeX: shape.bsAreaBeforeX,
                bsAreaBeforeY: shape.bsAreaBeforeY,
                bsAreaBeforeZ: shape.bsAreaBeforeZ,
                bsAreaAfterX: shape.bsAreaAfterX,
                bsAreaAfterY: shape.bsAreaAfterY,
                bsAreaAfterZ: shape.bsAreaAfterZ,
                fsPeakT: shape.fsPeakT,
                fsClassification: shape.fsClassification,
                fsPeakRotMag: result.fsPeakRotMag,
                fsProminence: shape.fsProminence,
                fsPeakRotX: result.fsPeakRotX,
                fsPeakRotY: result.fsPeakRotY,
                fsPeakRotZ: result.fsPeakRotZ,
                fsAreaBeforeX: shape.fsAreaBeforeX,
                fsAreaBeforeY: shape.fsAreaBeforeY,
                fsAreaBeforeZ: shape.fsAreaBeforeZ,
                fsAreaAfterX: shape.fsAreaAfterX,
                fsAreaAfterY: shape.fsAreaAfterY,
                fsAreaAfterZ: shape.fsAreaAfterZ,
                fsBsRatio: result.fsBsRatio,
                peakAcceleration: result.peakAcceleration,
                preStrokePitch: result.preStrokePitch,
                preStrokeRoll: result.preStrokeRoll,
                contactTV: contactTV,
                contactN: contactN,
                contactTVX: contactTVX,
                contactTVY: contactTVY,
                contactTVZ: contactTVZ,
                extremaSpread: extremaSpread,
                baselineTV: baselineTV,
                baselineN: baselineN,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                trajectoryHeading: swingHeading
            )
            detectionMeta = metadata
            DispatchQueue.main.async { self.lastDetectionMetadata = metadata }
        }

        // Cache motion slice for every detection (used by undo to send false positive CSV)
        let motionWindowEnd = shapeEvent.map { $0.fsPeakT + 1.0 } ?? (lastDeviceMotionSensorTime + 0.5)
        let motionWindowStart = shapeEvent.map { $0.bsTopT - 2.0 } ?? (motionWindowEnd - 5.0)
        rollingBufferLock.lock()
        let motionSlice = rollingMotionBuffer.elements(from: motionWindowStart, to: motionWindowEnd)
        rollingBufferLock.unlock()
        DispatchQueue.main.async { self.lastDetectionMotionSlice = motionSlice }

        // Capture 800Hz raw accel slice (if running) over the same time window
        eventBufferLock.lock()
        let rawAccelSlice = eventRawAccelBuffer.samples(in: motionWindowStart...motionWindowEnd)
        eventBufferLock.unlock()

        // Upload to Supabase (pending lifecycle — see docs/BACKEND.md)
        if let meta = detectionMeta {
            let clubType = settings.selectedClubTypeName
            let isAutoAdd = settings.autoAdd
            ClientEventLogger.log("swing.upload.dispatch", detail: [
                "motionSampleCount": .integer(motionSlice.count),
                "rawAccelSampleCount": .integer(rawAccelSlice.count),
                "clubType": clubType.map { .string($0) } ?? .null,
                "autoAdd": .bool(isAutoAdd)
            ])
            let eventId = SupabaseUploader.shared.onSwingDetected(
                metadata: meta,
                motionSlice: motionSlice,
                rawAccelSlice: rawAccelSlice,
                clubType: clubType,
                autoAdd: isAutoAdd,
                gateReport: gateReport
            )
            // Publish the event id so the auto-add UI flow can pair it with
            // the just-created stroke (for later false-positive marking on
            // undo). Only set in auto-add mode — manual mode returns nil.
            DispatchQueue.main.async { self.lastSwingEventId = eventId }

            // Re-upload the 800Hz slice once the batches covering this stroke
            // have actually been delivered. The synchronous slice above is
            // taken at confirm time and reliably stops before impact (see
            // uploadRawAccelLate); detection keeps its own timing, only the
            // stored copy is corrected.
            if let eventId {
                let start = motionWindowStart, end = motionWindowEnd
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + rawAccelSettleDelay) { [weak self] in
                    guard let self else { return }
                    self.eventBufferLock.lock()
                    let late = self.eventRawAccelBuffer.samples(in: start...end)
                    self.eventBufferLock.unlock()
                    guard late.count > rawAccelSlice.count else { return }
                    ClientEventLogger.log("swing.upload.rawLate.dispatch", detail: [
                        "eventId": .string(eventId.uuidString),
                        "wasCount": .integer(rawAccelSlice.count),
                        "nowCount": .integer(late.count)
                    ])
                    SupabaseUploader.shared.uploadRawAccelLate(eventId: eventId, slice: late)
                }
            }
        } else {
            ClientEventLogger.log("swing.upload.skipped.noMetadata")
        }

        // This detection accounts for the motion behind it, so a later
        // lookback capture must not reach back past here and re-upload the
        // same swing as a miss.
        markCaptureBoundary()

        DispatchQueue.main.async { self.lastDetectedSwing = swing }
        playFeedback()
    }

    func playFeedback() {
        // Three spaced double-pulses, 0.45s apart, so a detection is
        // unmistakable mid follow-through — a single buzz was too easy to miss.
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.45) {
                WKInterfaceDevice.current().play(.start)
                WKInterfaceDevice.current().play(.retry)
            }
        }
    }

    // MARK: - Formatting

    func f1(_ v: Double) -> String { String(format: "%.1f", v) }
    func f2(_ v: Double) -> String { String(format: "%.2f", v) }
    func f3(_ v: Double) -> String { String(format: "%.3f", v) }
}
