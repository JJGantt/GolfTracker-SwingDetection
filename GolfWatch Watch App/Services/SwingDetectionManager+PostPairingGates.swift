import Foundation
import CoreMotion
import StrokeSaverAlgorithms

extension SwingDetectionManager {

    /// Fire a confirmed unif detection + flash the "contact confirmed" UI light.
    func fireUnifConfirmed(shape: UnifiedShapeEvent, gate: PostPairingGateResult) {
        // Auto-detection succeeded — discard any rejected shapes that
        // accumulated since the last stroke. They're noise, not missed
        // swings: the system caught the real swing this time. Without
        // this clear, the NEXT manual-add (e.g. a stroke later in the
        // round) would erroneously upload these stale rejections as
        // false negatives.
        clearRejectionsSinceLastStroke()
        let result = unifiedDetector.buildResult(from: shape)
        fireSmartDetection(result: result, shapeEvent: shape,
            contactTV: gate.contactTV, contactN: gate.contactN,
            contactTVX: gate.contactTVX, contactTVY: gate.contactTVY, contactTVZ: gate.contactTVZ,
            extremaSpread: gate.extremaSpread,
            baselineTV: gate.baselineTV, baselineN: gate.baselineN,
            gateReport: gate.report)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.contactConfirmedRecently = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { self.contactConfirmedRecently = false }
        }
    }

    /// Primary post-pairing check: 100Hz device motion userAccel. Always runs from processDeviceMotion.
    /// Shapes that pass are fired immediately. Shapes that fail are moved to pendingUnifShapesDMFailed
    /// if 800Hz is running (putter mode), allowing a 800Hz override. Otherwise rejected.
    func checkPendingUnifShapesWithDM(currentMotionTime: TimeInterval) {
        eventsLock.lock()
        guard !pendingUnifShapes.isEmpty else { eventsLock.unlock(); return }

        // hasBatched controls whether DM-failed shapes get the 800Hz override
        // pass: whenever the stream is running, which is the whole session.
        let hasBatched = isBatchedAccelRunning

        var remaining: [UnifiedShapeEvent] = []
        for shape in pendingUnifShapes {
            let fsPeakT = shape.fsPeakT
            let bsTopT = shape.bsTopT
            let windowEnd = PostPairingGates.windowEnd(fsPeakT: fsPeakT)
            let baselineStart = PostPairingGates.baselineStart(bsTopT: bsTopT, fsPeakT: fsPeakT)

            if currentMotionTime < windowEnd {
                remaining.append(shape)
                continue
            }

            rollingBufferLock.lock()
            let contactSamples = rollingMotionBuffer.filter { $0.sensorTime >= bsTopT && $0.sensorTime <= windowEnd }
            let blSamples = rollingMotionBuffer.filter { $0.sensorTime >= baselineStart && $0.sensorTime <= bsTopT }
            let revSegment = rollingMotionBuffer.filter { $0.sensorTime >= bsTopT && $0.sensorTime <= PostPairingGates.reversalEnd(fsPeakT: fsPeakT) }
            rollingBufferLock.unlock()

            guard contactSamples.count >= 3 else {
                dprint("[UNIF_DM_SKIP type=\(shape.classification.rawValue) fsPeakT=\(f3(fsPeakT)) samples=\(contactSamples.count)]")
                continue
            }

            let gate = PostPairingGates.evaluate(
                contactTimes: contactSamples.map { $0.sensorTime },
                contactX: contactSamples.map { $0.userAccelX },
                contactY: contactSamples.map { $0.userAccelY },
                contactZ: contactSamples.map { $0.userAccelZ },
                baselineX: blSamples.map { $0.userAccelX },
                baselineY: blSamples.map { $0.userAccelY },
                baselineZ: blSamples.map { $0.userAccelZ },
                reversalRotMags: revSegment.map { $0.rotationMag },
                bsTopT: bsTopT, fsPeakT: fsPeakT, windowEnd: windowEnd,
                fsPeakRotMag: shape.fsPeakRotMag,
                bsPeakRotMag: sqrt(shape.bsPeakRotX * shape.bsPeakRotX + shape.bsPeakRotY * shape.bsPeakRotY + shape.bsPeakRotZ * shape.bsPeakRotZ),
                prePeakT: shape.prePeakT
            )

            if gate.passes {
                dprint("[UNIF_DM_CONFIRMED type=\(shape.classification.rawValue) fsPeakT=\(f3(fsPeakT)) ct=\(f3(gate.contactTV))(x=\(f3(gate.contactTVX)),y=\(f3(gate.contactTVY)),z=\(f3(gate.contactTVZ)),n=\(gate.contactN)) spread=\(gate.extremaSpread.map { f3($0) } ?? "nil") bl=\(f3(gate.baselineTV))(n=\(gate.baselineN))]")
                fireUnifConfirmed(shape: shape, gate: gate)
            } else if hasBatched {
                dprint("[UNIF_DM_FAILED type=\(shape.classification.rawValue) fsPeakT=\(f3(fsPeakT)) fails=[\(gate.fails.joined(separator: ", "))] — queuing for 800Hz override]")
                pendingUnifShapesDMFailed.append(shape)
            } else {
                dprint("[UNIF_DM_REJECTED type=\(shape.classification.rawValue) fsPeakT=\(f3(fsPeakT)) fails=[\(gate.fails.joined(separator: ", "))] ct=\(f3(gate.contactTV))(n=\(gate.contactN))]")
                // Retain for false-negative claim. If the user manually
                // adds a stroke shortly after this, we ship the rejected
                // shape + which gate killed it as training data.
                recordRejection(shape: shape, gate: gate, stage: "DM")
            }
        }
        pendingUnifShapes = remaining
        eventsLock.unlock()
    }

    /// 800Hz override: only processes shapes that already failed the 100Hz DM check.
    /// Fires if raw accel passes; otherwise rejects. Called from feedRawAccelSample.
    func checkPendingUnifShapes(currentRawTime: TimeInterval) {
        eventsLock.lock()
        guard !pendingUnifShapesDMFailed.isEmpty else { eventsLock.unlock(); return }

        var remaining: [UnifiedShapeEvent] = []
        for shape in pendingUnifShapesDMFailed {
            let fsPeakT = shape.fsPeakT
            let bsTopT = shape.bsTopT
            let windowEnd = PostPairingGates.windowEnd(fsPeakT: fsPeakT)
            let baselineStart = PostPairingGates.baselineStart(bsTopT: bsTopT, fsPeakT: fsPeakT)

            if currentRawTime < windowEnd {
                remaining.append(shape)
                continue
            }

            eventBufferLock.lock()
            let contactSamples = eventRawAccelBuffer.samples(in: bsTopT...windowEnd)
            let blSamples = eventRawAccelBuffer.samples(in: baselineStart...bsTopT)
            eventBufferLock.unlock()

            guard contactSamples.count >= 3 else {
                dprint("[UNIF_800HZ_SKIP type=\(shape.classification.rawValue) fsPeakT=\(f3(fsPeakT)) samples=\(contactSamples.count) (insufficient)]")
                continue
            }

            // Reversal segment comes from 100Hz DM buffer — 800Hz raw accel has no rotation channel.
            let revEnd = PostPairingGates.reversalEnd(fsPeakT: fsPeakT)
            var revRotMags: [Double] = []
            if revEnd > bsTopT {
                rollingBufferLock.lock()
                revRotMags = rollingMotionBuffer
                    .filter { $0.sensorTime >= bsTopT && $0.sensorTime <= revEnd }
                    .map { $0.rotationMag }
                rollingBufferLock.unlock()
            }

            let gate = PostPairingGates.evaluate(
                contactTimes: contactSamples.map { $0.sensorTime },
                contactX: contactSamples.map { $0.rawAccelX },
                contactY: contactSamples.map { $0.rawAccelY },
                contactZ: contactSamples.map { $0.rawAccelZ },
                baselineX: blSamples.map { $0.rawAccelX },
                baselineY: blSamples.map { $0.rawAccelY },
                baselineZ: blSamples.map { $0.rawAccelZ },
                reversalRotMags: revRotMags,
                bsTopT: bsTopT, fsPeakT: fsPeakT, windowEnd: windowEnd,
                fsPeakRotMag: shape.fsPeakRotMag,
                bsPeakRotMag: sqrt(shape.bsPeakRotX * shape.bsPeakRotX + shape.bsPeakRotY * shape.bsPeakRotY + shape.bsPeakRotZ * shape.bsPeakRotZ),
                prePeakT: shape.prePeakT
            )

            if gate.passes {
                dprint("[UNIF_800HZ_OVERRIDE type=\(shape.classification.rawValue) fsPeakT=\(f3(fsPeakT)) ct=\(f3(gate.contactTV))(x=\(f3(gate.contactTVX)),y=\(f3(gate.contactTVY)),z=\(f3(gate.contactTVZ)),n=\(gate.contactN)) spread=\(gate.extremaSpread.map { f3($0) } ?? "nil") bl=\(f3(gate.baselineTV))(n=\(gate.baselineN))]")
                fireUnifConfirmed(shape: shape, gate: gate)
            } else {
                dprint("[UNIF_800HZ_REJECTED type=\(shape.classification.rawValue) fsPeakT=\(f3(fsPeakT)) fails=[\(gate.fails.joined(separator: ", "))] ct=\(f3(gate.contactTV))(n=\(gate.contactN)) spread=\(gate.extremaSpread.map { f3($0) } ?? "nil") bl=\(f3(gate.baselineTV))(n=\(gate.baselineN))]")
                // Same retention logic as the DM-stage rejection — see
                // checkPendingUnifShapesWithDM. False-negative claim path
                // pulls the most recent rejection regardless of which
                // stage rejected it.
                recordRejection(shape: shape, gate: gate, stage: "raw800")
            }
        }
        pendingUnifShapesDMFailed = remaining
        eventsLock.unlock()
    }

    /// Expire pending unified shapes that have been waiting too long without raw accel data.
    /// Called from the motion data path (100Hz) so we can detect when raw data isn't flowing.
    func expireStaleTVShapes(motionTime: TimeInterval) {
        // Only check once per second
        guard motionTime - lastStaleCheckTime >= 1.0 else { return }
        lastStaleCheckTime = motionTime

        eventsLock.lock()
        let hasUnifShapes = !pendingUnifShapes.isEmpty
        let hasDMFailed = !pendingUnifShapesDMFailed.isEmpty
        guard hasUnifShapes || hasDMFailed else { eventsLock.unlock(); return }

        let staleThreshold: TimeInterval = 3.0  // seconds past window end before we give up
        var expiredCount = 0

        // Expire pending unified shapes (waiting for DM check — shouldn't happen since DM always runs)
        if hasUnifShapes {
            var remaining: [UnifiedShapeEvent] = []
            for shape in pendingUnifShapes {
                let windowEnd = PostPairingGates.windowEnd(fsPeakT: shape.fsPeakT)
                let staleness = motionTime - windowEnd
                if staleness > staleThreshold {
                    dprint("[UNIF_DM_EXPIRED type=\(shape.classification.rawValue) fsPeakT=\(f3(shape.fsPeakT)) staleness=\(f3(staleness))s]")
                    expiredCount += 1
                } else {
                    remaining.append(shape)
                }
            }
            pendingUnifShapes = remaining
        }

        // Expire DM-failed shapes waiting for 800Hz override
        if hasDMFailed {
            var remaining: [UnifiedShapeEvent] = []
            for shape in pendingUnifShapesDMFailed {
                let windowEnd = PostPairingGates.windowEnd(fsPeakT: shape.fsPeakT)
                let staleness = motionTime - windowEnd
                if staleness > staleThreshold {
                    dprint("[UNIF_800HZ_EXPIRED type=\(shape.classification.rawValue) fsPeakT=\(f3(shape.fsPeakT)) staleness=\(f3(staleness))s — no 800Hz data]")
                    expiredCount += 1
                } else {
                    remaining.append(shape)
                }
            }
            pendingUnifShapesDMFailed = remaining
        }

        eventsLock.unlock()

        if expiredCount > 0 && !rawAccelMissingWarned {
            rawAccelMissingWarned = true
            let batchAuth = CMBatchedSensorManager.authorizationStatus
            dprint("[RAW_ACCEL_MISSING \(expiredCount) putt(s) expired — 800Hz not delivering. auth=\(batchAuth.rawValue)]")
            DispatchQueue.main.async { self.rawAccelAuthOK = (batchAuth == .authorized) }
        }
    }
}
