import Foundation
@preconcurrency import CoreMotion

// Steps since the last detected swing, for the practice-swing gate.
extension SwingDetectionManager {

    /// Step-count gate threshold used by the practice-shot dedup logic.
    /// Read live from UserDefaults so the iOS dev settings slider can tune
    /// it. Default 10. Set arbitrarily high to disable the gate.
    static let stepGateThresholdKey = "practiceStepGateThreshold"
    var stepGateThreshold: Int {
        let v = UserDefaults.standard.integer(forKey: Self.stepGateThresholdKey)
        return v > 0 ? v : 10
    }

    func startPedometerMonitoring() {
        guard !pedometerStartedMonitoring else { return }
        guard CMPedometer.isStepCountingAvailable() else { return }
        pedometerStartedMonitoring = true
        pedometerStartDate = Date()
        pedometer.startUpdates(from: pedometerStartDate) { [weak self] data, _ in
            guard let self = self, let data = data else { return }
            let steps = data.numberOfSteps.intValue
            DispatchQueue.main.async { self.stepsSinceLastDetectedSwing = steps }
        }
    }

    func stopPedometerMonitoring() {
        guard pedometerStartedMonitoring else { return }
        pedometerStartedMonitoring = false
        pedometer.stopUpdates()
        DispatchQueue.main.async { self.stepsSinceLastDetectedSwing = 0 }
    }

    /// Reset the step counter — called from `fireSmartDetection` so each
    /// detected swing starts a fresh inter-swing step-tally window.
    func resetStepsSinceLastDetectedSwing() {
        guard pedometerStartedMonitoring else { return }
        pedometer.stopUpdates()
        pedometerStartDate = Date()
        DispatchQueue.main.async { self.stepsSinceLastDetectedSwing = 0 }
        pedometer.startUpdates(from: pedometerStartDate) { [weak self] data, _ in
            guard let self = self, let data = data else { return }
            let steps = data.numberOfSteps.intValue
            DispatchQueue.main.async { self.stepsSinceLastDetectedSwing = steps }
        }
    }
}
