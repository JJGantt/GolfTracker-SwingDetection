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
        cLog("[800Hz_PUTT_START]")
    }

    func stopBatchedAccelForPutt() {
        guard batchedAccelForPutt else { return }
        batchedAccelForPutt = false
        setupEndTimeoutTimer?.invalidate()
        setupEndTimeoutTimer = nil
        syncRawAccelHardwareState()
        cLog("[800Hz_PUTT_STOP]")
    }

    func onUnifSetupStarted() {
        guard isPutterSelected else { return }
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
        if isRecording {
            return true
        }
        if isDataCollectionMode {
            return true
        }
        if !CMBatchedSensorManager.isAccelerometerSupported {
            return true
        }
        return WorkoutManager.shared.session?.state == .running
    }

    var shouldRunRawAccelHardware: Bool {
        if isRecording {
            return true
        }
        guard isMonitoring, rawAccelRunningForCapture else {
            return false
        }
        if isDataCollectionMode && dataCollectionHighFreq {
            return true
        }
        switch detectionMode {
        case .unifDetect:
            return batchedAccelForPutt
        case .off:
            return false
        }
    }

    func syncRawAccelHardwareState() {
        let shouldRun = shouldRunRawAccelHardware

        if shouldRun {
            guard canStartRawAccelNow else { return }
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
                            self.cLog("[BATCH_START samples=\(batch.count) t=[\(self.f3(first.timestamp)),\(self.f3(last.timestamp))]]")
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
        if isRecording && t >= recordingStartSensorTime && t <= recordingStopSensorTime {
            rawAccelDataPoints.append(dp)
        }
        // Rolling 3-min raw accel buffer (disabled during manual recording)
        if isMonitoring && !isRecording {
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

    /// Stop the raw accelerometer only when neither monitoring nor recording needs it.
    func stopBatchedAccelIfUnneeded() {
        guard isBatchedAccelRunning, !isMonitoring, !isRecording else { return }
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
