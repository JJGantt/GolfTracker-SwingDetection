import Foundation
import CoreMotion

extension SwingDetectionManager {

    // MARK: - Event Capture

    /// Start/stop raw accelerometer based on whether event capture conditions are met.
    /// For unifDetect mode, 800Hz is managed dynamically (putter + setup), but the event
    /// buffer flag stays on so data flows when 800Hz is running.
    func updateRawAccelForCapture() {
        let shouldCapture = detectionMode == .unifDetect
        if shouldCapture && !rawAccelRunningForCapture {
            rawAccelRunningForCapture = true

            eventBufferLock.lock()
            eventRawAccelBuffer.clear()
            eventBufferLock.unlock()
            syncRawAccelHardwareState()
            dprint("⌚ [SwingDetection] Event capture enabled (800Hz setup-gated putter)")
        } else if !shouldCapture && rawAccelRunningForCapture {
            rawAccelRunningForCapture = false

            eventBufferLock.lock()
            eventRawAccelBuffer.clear()
            eventBufferLock.unlock()
            batchedAccelForPutt = false
            setupEndTimeoutTimer?.invalidate()
            setupEndTimeoutTimer = nil
            syncRawAccelHardwareState()
            dprint("⌚ [SwingDetection] Event capture disabled")
        }
    }

    // MARK: - Dynamic 800Hz for Putter

    func startBatchedAccelForPutt() {
        guard !batchedAccelForPutt else { return }
        batchedAccelForPutt = true
        setupEndTimeoutTimer?.invalidate()
        setupEndTimeoutTimer = nil
        syncRawAccelHardwareState()
        ClientEventLogger.log("rawAccel.putt.start", level: .diagnostic, detail: [
            "isPutterSelected": .bool(isPutterSelected),
            "selectedClubType": selectedClubTypeName.map { .string($0) } ?? .null,
            "workoutSessionState": .string("\(WorkoutManager.shared.session?.state.rawValue ?? -1)"),
            "canStartRawAccelNow": .bool(canStartRawAccelNow),
            "shouldRunRawAccelHardware": .bool(shouldRunRawAccelHardware)
        ])
        dprint("[800Hz_PUTT_START]")
    }

    func stopBatchedAccelForPutt() {
        guard batchedAccelForPutt else { return }
        batchedAccelForPutt = false
        setupEndTimeoutTimer?.invalidate()
        setupEndTimeoutTimer = nil
        syncRawAccelHardwareState()
        dprint("[800Hz_PUTT_STOP]")
    }

    func onUnifSetupStarted() {
        ClientEventLogger.log("rawAccel.setupStarted", level: .diagnostic, detail: [
            "isPutterSelected": .bool(isPutterSelected),
            "selectedClubType": selectedClubTypeName.map { .string($0) } ?? .null,
            "workoutSessionState": .string("\(WorkoutManager.shared.session?.state.rawValue ?? -1)")
        ])
        guard isPutterSelected || !raw800PutterOnly else {
            ClientEventLogger.log("rawAccel.setupStarted.bail.notPutter", level: .diagnostic)
            return
        }
        setupEndTimeoutTimer?.invalidate()
        setupEndTimeoutTimer = nil
        startBatchedAccelForPutt()
    }

    func onUnifSetupEnded() {
        guard batchedAccelForPutt else { return }
        // Start timeout — if no BS top pairs within setupEndTimeoutS, spin down
        setupEndTimeoutTimer?.invalidate()
        setupEndTimeoutTimer = Timer.scheduledTimer(withTimeInterval: setupEndTimeoutS, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            // Only spin down if no pending shapes are being checked
            self.eventsLock.lock()
            let hasPending = !self.pendingUnifShapes.isEmpty
            self.eventsLock.unlock()
            if !hasPending {
                self.stopBatchedAccelForPutt()
            }
        }
    }

    var canStartRawAccelNow: Bool {
        if !CMBatchedSensorManager.isAccelerometerSupported {
            return true
        }
        return WorkoutManager.shared.session?.state == .running
    }

    var shouldRunRawAccelHardware: Bool {
        guard isMonitoring else { return false }
        guard rawAccelRunningForCapture else { return false }
        // Deliberately NOT special-cased for Swing Test Mode. Running 800Hz
        // continuously there was tried and reverted: the mode exists to
        // reproduce what happens in a round, and a stream that is always on
        // cannot reproduce a stream that spins up too late. Whatever the gating
        // does to a real putt, it must do here.
        switch detectionMode {
        case .unifDetect:
            // Always setup-gated — hardware only runs during an active
            // detection window (setup start → 3s after setup end or shape
            // resolution). raw800PutterOnly only controls which club types
            // trigger onUnifSetupStarted; it does NOT mean "always on."
            return batchedAccelForPutt
        case .off:
            // Nothing else arms the 800Hz hardware now that Sensor Capture is
            // gone; detection is the only consumer.
            return false
        }
    }

    func syncRawAccelHardwareState() {
        let shouldRun = shouldRunRawAccelHardware
        let canStart = canStartRawAccelNow

        if shouldRun {
            guard canStart else {
                ClientEventLogger.log("rawAccel.sync.bail.canStartFalse", level: .diagnostic, detail: [
                    "workoutSessionState": .string("\(WorkoutManager.shared.session?.state.rawValue ?? -1)"),
                    "isMonitoring": .bool(isMonitoring),
                    "isAccelerometerSupported": .bool(CMBatchedSensorManager.isAccelerometerSupported)
                ])
                return
            }
            ensureBatchedAccelRunning()
        } else {
            forceStopBatchedAccel()
        }
    }

    /// Start raw accelerometer if not already running.
    func ensureBatchedAccelRunning() {
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
                        self.rawAccelQueue.addOperation { [weak self] in
                            guard let self = self else { return }
                            for sample in batch {
                                self.feedRawAccelSample(x: sample.acceleration.x,
                                                        y: sample.acceleration.y,
                                                        z: sample.acceleration.z,
                                                        t: sample.timestamp)
                            }
                        }
                    }
                } catch {
                    self.phoneLog("[SwingDetection] CMBatchedSensor stream ended: \(error)")
                }
            }
            phoneLog("[SwingDetection] Raw accel started @800Hz (CMBatchedSensorManager)")
        } else if motionManager.isAccelerometerAvailable {
            isBatchedAccelRunning = true
            isUsingFallbackRawAccel = true
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

    /// Common sample handler — called from both the batched and fallback paths.
    func feedRawAccelSample(x: Double, y: Double, z: Double, t: TimeInterval) {
        latestRawAccelTime = t
        let mag = sqrt(x * x + y * y + z * z)
        let dp = RawAccelDataPoint(sensorTime: t, rawAccelX: x, rawAccelY: y, rawAccelZ: z, rawAccelMag: mag)
        // Rolling 3-min raw accel buffer — fed continuously while monitoring.
        if isMonitoring {
            rollingBufferLock.lock()
            rollingRawAccelBuffer.append(dp)
            let cutoff = t - rollingBufferDuration
            while let first = rollingRawAccelBuffer.first, first.sensorTime < cutoff {
                rollingRawAccelBuffer.removeFirst()
            }
            rollingBufferLock.unlock()
        }
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

    /// Stop the raw accelerometer when monitoring is no longer active.
    func stopBatchedAccelIfUnneeded() {
        guard isBatchedAccelRunning, !isMonitoring else { return }
        forceStopBatchedAccel()
    }

    /// Force-stop the raw accelerometer regardless of monitoring state.
    /// Used by dynamic 800Hz putter logic to spin down while monitoring continues.
    func forceStopBatchedAccel() {
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
}
