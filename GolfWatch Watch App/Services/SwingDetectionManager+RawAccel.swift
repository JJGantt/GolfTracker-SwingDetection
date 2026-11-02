import Foundation
@preconcurrency import CoreMotion

extension SwingDetectionManager {

    // MARK: - Event Capture

    /// Arm or disarm event capture (the 800Hz event buffer) with the detection
    /// mode, then bring the hardware in line.
    func updateRawAccelForCapture() {
        let shouldCapture = detectionMode == .unifDetect
        if shouldCapture && !rawAccelRunningForCapture {
            rawAccelRunningForCapture = true

            eventBufferLock.lock()
            eventRawAccelBuffer.clear()
            eventBufferLock.unlock()
            syncRawAccelHardwareState()
            dprint("⌚ [SwingDetection] Event capture enabled (800Hz for the whole session)")
        } else if !shouldCapture && rawAccelRunningForCapture {
            rawAccelRunningForCapture = false

            eventBufferLock.lock()
            eventRawAccelBuffer.clear()
            eventBufferLock.unlock()
            syncRawAccelHardwareState()
            dprint("⌚ [SwingDetection] Event capture disabled")
        }
    }

    var canStartRawAccelNow: Bool {
        if !CMBatchedSensorManager.isAccelerometerSupported {
            return true
        }
        return WorkoutManager.currentSessionState == .running
    }

    /// 800Hz runs for the whole monitoring session — every round, and every
    /// Swing Test session, which follows the same rule so it still reproduces
    /// a round.
    ///
    /// It used to arm at each setup and spin down 3s after the setup ended.
    /// That saved little: the spin-down Timer was scheduled from `motionQueue`,
    /// an OperationQueue with no run loop, so it never fired and windows ran on
    /// for minutes (68% of the 2026-09-07 round was covered anyway). And the
    /// arm/disarm cycle is where the stream's failures lived: a stream that
    /// went silent while marked armed had no path back until monitoring
    /// stopped (2026-08-31, 35 minutes with no vibration data). A dead stream
    /// is now recovered by the watchdog in `checkRaw800Liveness`.
    var shouldRunRawAccelHardware: Bool {
        let state = engine
        guard monitoringActive, state.rawAccelRunningForCapture else { return false }
        switch state.detectionMode {
        case .unifDetect:
            return true
        case .off:
            return false
        }
    }

    func syncRawAccelHardwareState() {
        rawAccelControlLock.lock()
        defer { rawAccelControlLock.unlock() }

        if shouldRunRawAccelHardware {
            guard canStartRawAccelNow else {
                ClientEventLogger.log("rawAccel.sync.bail.canStartFalse", level: .diagnostic, detail: [
                    "workoutSessionState": .string("\(WorkoutManager.currentSessionState.rawValue)"),
                    "isMonitoring": .bool(monitoringActive),
                    "isAccelerometerSupported": .bool(CMBatchedSensorManager.isAccelerometerSupported)
                ])
                return
            }
            startRawAccelLocked()
        } else {
            stopRawAccelLocked()
        }
    }

    /// Watchdog recovery: tear the stream down and bring it back up in one
    /// locked step. A no-op when the stream shouldn't be running, or can't be
    /// (no running workout session — delivery would stay silent regardless).
    func restartRawAccel() {
        rawAccelControlLock.lock()
        defer { rawAccelControlLock.unlock() }
        guard shouldRunRawAccelHardware, canStartRawAccelNow else { return }
        stopRawAccelLocked()
        startRawAccelLocked()
    }

    /// Stop the raw accelerometer when monitoring is no longer active.
    func stopBatchedAccelIfUnneeded() {
        rawAccelControlLock.lock()
        defer { rawAccelControlLock.unlock() }
        guard !monitoringActive else { return }
        stopRawAccelLocked()
    }

    // Both below require `rawAccelControlLock`. Start and stop used to run
    // unlocked from motionQueue, rawAccelQueue and main, so a stop's
    // `stopAccelerometerUpdates()` could land after a concurrent start and
    // leave the flags saying running with the hardware off.

    private func startRawAccelLocked() {
        guard !isBatchedAccelRunning else { return }

        if CMBatchedSensorManager.isAccelerometerSupported {
            let batchAuth = CMBatchedSensorManager.authorizationStatus
            if batchAuth != .authorized {
                dprint("⌚ [SwingDetection] CMBatchedSensorManager auth=\(batchAuth.rawValue) — raw accel may not deliver data")
                DispatchQueue.main.async { self.rawAccelAuthOK = false }
            } else {
                DispatchQueue.main.async { self.rawAccelAuthOK = true }
            }
            isBatchedAccelRunning = true
            isUsingFallbackRawAccel = false
            noteRawStreamArmed()
            batchedSensorManager.startAccelerometerUpdates()
            batchedAccelTask = Task(priority: .userInitiated) { [weak self] in
                guard let self = self else { return }
                var batchCount = 0
                do {
                    for try await batch in self.batchedSensorManager.accelerometerUpdates() {
                        batchCount += 1
                        // Log only first batch to confirm stream is running
                        if batchCount == 1, let first = batch.first, let last = batch.last {
                            dprint("⌚ [BATCH_START samples=\(batch.count) t=[\(self.f3(first.timestamp)),\(self.f3(last.timestamp))]]")
                            DispatchQueue.main.async { self.rawAccelAuthOK = true }
                            self.rawAccelMissingWarned = false
                        }
                        self.noteRawBatchArrived()
                        // Copied out as plain values: the sensor's own sample
                        // objects are not safe to hand to another queue.
                        let samples = batch.map {
                            (x: $0.acceleration.x, y: $0.acceleration.y, z: $0.acceleration.z, t: $0.timestamp)
                        }
                        self.rawAccelQueue.addOperation { [weak self] in
                            guard let self = self else { return }
                            for sample in samples {
                                self.feedRawAccelSample(x: sample.x, y: sample.y, z: sample.z, t: sample.t)
                            }
                        }
                    }
                } catch {
                    // The stream dying is the outage that matters — say so to
                    // the server, not just the local console.
                    ClientEventLogger.log("rawAccel.stream.ended", detail: [
                        "error": .string("\(error)"),
                        "batches": .integer(batchCount)
                    ])
                    self.phoneLog("[SwingDetection] CMBatchedSensor stream ended: \(error)")
                }
                ClientEventLogger.log("rawAccel.stream.loopExited", detail: [
                    "batches": .integer(batchCount)
                ])
            }
            phoneLog("[SwingDetection] Raw accel started @800Hz (CMBatchedSensorManager)")
        } else if motionManager.isAccelerometerAvailable {
            isBatchedAccelRunning = true
            isUsingFallbackRawAccel = true
            noteRawStreamArmed()
            motionManager.accelerometerUpdateInterval = 0.01
            motionManager.startAccelerometerUpdates(to: rawAccelQueue) { [weak self] data, error in
                guard let self = self, let data = data else { return }
                self.feedRawAccelSample(x: data.acceleration.x,
                                        y: data.acceleration.y,
                                        z: data.acceleration.z,
                                        t: data.timestamp)
            }
            phoneLog("[SwingDetection] CMBatchedSensorManager not supported — raw accel fallback @100Hz")
        } else {
            phoneLog("[SwingDetection] ERROR: no raw accelerometer source available")
        }
    }

    private func stopRawAccelLocked() {
        guard isBatchedAccelRunning else { return }
        isBatchedAccelRunning = false
        if isUsingFallbackRawAccel {
            motionManager.stopAccelerometerUpdates()
        } else {
            batchedAccelTask?.cancel()
            batchedAccelTask = nil
            batchedSensorManager.stopAccelerometerUpdates()
        }
        isUsingFallbackRawAccel = false
        dprint("⌚ [SwingDetection] Raw accel stopped")
    }

    /// Common sample handler — called from both the batched and fallback paths.
    func feedRawAccelSample(x: Double, y: Double, z: Double, t: TimeInterval) {
        latestRawAccelTime.withLock { $0 = t }
        let mag = sqrt(x * x + y * y + z * z)
        let dp = RawAccelDataPoint(sensorTime: t, rawAccelX: x, rawAccelY: y, rawAccelZ: z, rawAccelMag: mag)
        if rawAccelRunningForCapture {
            eventBufferLock.lock()
            eventRawAccelBuffer.append(dp)
            let cutoff = t - eventBufferDuration
            eventRawAccelBuffer.trim(olderThan: cutoff)
            eventBufferLock.unlock()
            // Check pending unified shapes for TV contact confirmation
            checkPendingUnifShapes(currentRawTime: t)
        }
    }
}

// 800Hz stream liveness: the watchdog that notices a stream armed but silent.
extension SwingDetectionManager {

    /// Called from the batch-delivery loop (~2Hz). Marks the stream live and
    /// closes out a logged outage.
    func noteRawBatchArrived() {
        let now = Date()
        let recoveredAfter: TimeInterval? = raw800Liveness.withLock { l in
            l.lastBatchWall = now
            l.restartAttempts = 0
            l.nextRestartAt = nil
            l.state = .live
            defer { l.downLogged = false; l.downSince = nil }
            return l.downLogged ? (l.downSince.map { now.timeIntervalSince($0) } ?? 0) : nil
        }
        if let downFor = recoveredAfter {
            ClientEventLogger.log("rawAccel.stream.up", detail: [
                "downSeconds": .double(downFor)
            ])
        }
        DispatchQueue.main.async {
            if self.raw800State != .live { self.raw800State = .live }
            self.raw800DownSince = nil
        }
    }

    /// The stream was just (re)started. Silence is measured from here. It was
    /// measured from the last batch of whatever ran before, so every restart
    /// logged a phantom outage spanning the whole gap — 41 of the 42
    /// `stream.down` rows on 2026-09-07 were that, not real dropouts.
    func noteRawStreamArmed() {
        raw800Liveness.withLock { $0.lastBatchWall = Date() }
    }

    /// Called from the 100Hz motion tick, throttled to ~1Hz. Detects
    /// running-but-silent, logs the DOWN transition once, and restarts the
    /// stream with backoff until batches flow again.
    func checkRaw800Liveness(sensorTime: TimeInterval) {
        enum Verdict { case none, off, silent(Double, wentDown: Date?, restart: (attempt: Int, backoff: Double)?) }
        let running = isBatchedAccelRunning
        let now = Date()
        let verdict: Verdict = raw800Liveness.withLock { l in
            guard sensorTime - l.lastCheckSensorTime >= 1.0 else { return .none }
            l.lastCheckSensorTime = sensorTime
            guard running else {
                guard l.state != .off else { return .none }
                l.state = .off
                return .off
            }
            guard let last = l.lastBatchWall else { return .none }
            let silent = now.timeIntervalSince(last)
            guard silent > 2.0 else { return .none }
            var wentDown: Date?
            if !l.downLogged {
                l.downLogged = true
                l.state = .down
                l.downSince = last
                wentDown = last
            }
            // Watchdog. Nothing else ever restarts a stream that dies while it
            // is meant to be running — the 2026-08-31 outage sat dead for 35
            // minutes.
            if let next = l.nextRestartAt, now < next {
                return .silent(silent, wentDown: wentDown, restart: nil)
            }
            l.restartAttempts += 1
            let backoff = min(60.0, 2.0 * pow(2.0, Double(l.restartAttempts - 1)))
            l.nextRestartAt = now.addingTimeInterval(backoff)
            return .silent(silent, wentDown: wentDown, restart: (l.restartAttempts, backoff))
        }
        switch verdict {
        case .none:
            return
        case .off:
            DispatchQueue.main.async { self.raw800State = .off }
        case let .silent(silent, wentDown, restart):
            if let last = wentDown {
                ClientEventLogger.log("rawAccel.stream.down", detail: [
                    "silentSeconds": .double(silent)
                ])
                DispatchQueue.main.async {
                    self.raw800State = .down
                    self.raw800DownSince = last
                }
            }
            guard let restart else { return }
            ClientEventLogger.log("rawAccel.stream.restart", detail: [
                "attempt": .integer(restart.attempt),
                "silentSeconds": .double(silent),
                "nextRetrySeconds": .double(restart.backoff),
                "canStart": .bool(canStartRawAccelNow)
            ])
            restartRawAccel()
        }
    }
}
