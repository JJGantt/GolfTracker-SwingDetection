import Foundation
import os
import StrokeSaverAlgorithms

// Evidence for swings the detector missed: shapes the post-pairing gates
// rejected since the last stroke, and the Missed It lookback window.
extension SwingDetectionManager {

    /// How many rejections are waiting to be claimed, for the debug readouts.
    var pendingRejectionCount: Int {
        rejectionsLock.lock()
        defer { rejectionsLock.unlock() }
        return rejectedShapesSinceLastStroke.count
    }

    /// Called by PostPairingGates when a shape is rejected outright (DM
    /// gate failed and 800Hz isn't running, or 800Hz override also failed).
    /// Captures the same motion + raw accel slices we'd ship for a real
    /// detection, plus the gate result with `fails` populated.
    func recordRejection(shape: UnifiedShapeEvent, gate: PostPairingGateResult, stage: String) {
        let motionWindowStart = shape.bsTopT - 2.0
        let motionWindowEnd = shape.fsPeakT + 1.0
        rollingBufferLock.lock()
        let motionSlice = rollingMotionBuffer.elements(from: motionWindowStart, to: motionWindowEnd)
        rollingBufferLock.unlock()
        eventBufferLock.lock()
        let rawAccelSlice = eventRawAccelBuffer.samples(in: motionWindowStart...motionWindowEnd)
        eventBufferLock.unlock()

        let rejection = RejectedShape(
            shape: shape, gate: gate,
            motionSlice: motionSlice, rawAccelSlice: rawAccelSlice,
            rejectedAt: Date(), stage: stage
        )
        rejectionsLock.lock()
        rejectedShapesSinceLastStroke.append(rejection)
        rejectionsLock.unlock()
    }

    /// Pops and returns ALL rejected shapes accumulated since the last
    /// stroke. Clears the buffer. Used by the manual-stroke-add path to
    /// upload every recent rejection as a false-negative.
    func claimAllRejectionsSinceLastStroke() -> [RejectedShape] {
        rejectionsLock.lock()
        defer { rejectionsLock.unlock() }
        let claimed = rejectedShapesSinceLastStroke
        rejectedShapesSinceLastStroke.removeAll()
        return claimed
    }

    /// Discards the buffer without uploading. Used by the auto-detect
    /// success path — when the system DID catch a swing, intermediate
    /// rejections are noise, not missed swings.
    func clearRejectionsSinceLastStroke() {
        rejectionsLock.lock()
        defer { rejectionsLock.unlock() }
        rejectedShapesSinceLastStroke.removeAll()
    }

    /// Re-read the 800Hz ring for an already-decided window. Used after
    /// `rawAccelSettleDelay` so a capture is not stored missing the batch that
    /// carried the impact.
    func rawAccelSlice(from: TimeInterval, to: TimeInterval) -> [RawAccelDataPoint] {
        eventBufferLock.lock()
        defer { eventBufferLock.unlock() }
        return eventRawAccelBuffer.samples(in: from...to)
    }

    /// Called on every fired detection to advance the boundary. Motion up to
    /// here has an event of its own and must not be re-captured.
    func markCaptureBoundary() {
        sensorClock.withLock { $0.captureBoundary = $0.latestSample }
    }

    /// Grab the raw motion window for a swing the detector said nothing about.
    ///
    /// The window ends now and starts at the later of (now − `lookbackMaxSeconds`)
    /// and the last boundary, so it shrinks automatically to cover only ground
    /// nothing has claimed yet — often well under the maximum. Any rejections
    /// inside it come along, and an empty rejection list is the informative
    /// case: the swing never even paired.
    ///
    /// Returns nil when the window is empty, which means the boundary is
    /// already at "now" — a detection just fired, or the button was already
    /// pressed and there is nothing new to send.
    func captureLookbackWindow() -> LookbackCapture? {
        // Read the window and claim it in one step, so a detection firing
        // meanwhile cannot move the boundary between the two.
        let (windowEnd, windowStart, boundary) = sensorClock.withLock { clock in
            let end = clock.latestSample
            let start = max(end - Self.lookbackMaxSeconds, clock.captureBoundary)
            let was = clock.captureBoundary
            if end > start { clock.captureBoundary = end }
            return (end, start, was)
        }
        guard windowEnd > windowStart else {
            ClientEventLogger.log("lookback.capture.empty", detail: [
                "windowEnd": .double(windowEnd),
                "boundary": .double(boundary)
            ])
            return nil
        }

        rollingBufferLock.lock()
        let motionSlice = rollingMotionBuffer.elements(from: windowStart, to: windowEnd)
        rollingBufferLock.unlock()

        eventBufferLock.lock()
        let rawAccelSlice = eventRawAccelBuffer.samples(in: windowStart...windowEnd)
        eventBufferLock.unlock()

        // Consume them — they're attached to this capture now, and in test
        // mode there is no stroke to otherwise drain the buffer.
        let inCapture: (RejectedShape) -> Bool = {
            $0.shape.fsPeakT >= windowStart && $0.shape.fsPeakT <= windowEnd
        }
        rejectionsLock.lock()
        let inWindow = rejectedShapesSinceLastStroke.filter(inCapture)
        rejectedShapesSinceLastStroke.removeAll(where: inCapture)
        rejectionsLock.unlock()

        ClientEventLogger.log("lookback.capture", detail: [
            "windowSeconds": .double(windowEnd - windowStart),
            "motionSamples": .integer(motionSlice.count),
            "rawAccelSamples": .integer(rawAccelSlice.count),
            "rejections": .integer(inWindow.count)
        ])

        return LookbackCapture(
            motionSlice: motionSlice,
            rawAccelSlice: rawAccelSlice,
            rejections: inWindow,
            windowSeconds: windowEnd - windowStart,
            windowStart: windowStart,
            windowEnd: windowEnd
        )
    }
}
