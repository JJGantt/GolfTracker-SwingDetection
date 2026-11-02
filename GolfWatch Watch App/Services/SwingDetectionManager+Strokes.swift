import Foundation
import CoreLocation
import StrokeSaverAlgorithms

// What happens to a detection once the round has it: practice-swing
// replacement, the per-stroke caches, undo.
extension SwingDetectionManager {

    /// Whether a new auto-added swing should replace the previous auto-added
    /// stroke (= treat as practice swing). True when **both** signals say
    /// the user hasn't moved between the previous stroke and the new
    /// detection: GPS distance < ignorePracticeRadius AND step count <
    /// stepGateThreshold. Step count is read from
    /// `stepsSinceLastDetectedSwing` (live CMPedometer counter, reset on
    /// every detection).
    ///
    /// Putts are exempted (always returns false) — they're inherently
    /// short and would dedup tap-ins. Same for non-putt strokes outside
    /// the radius+step gates.
    ///
    /// Both gates configurable via UserDefaults — set the step threshold
    /// arbitrarily high to disable the step half of the AND.
    func shouldReplacePreviousStroke(newLocation: CLLocationCoordinate2D,
                                     previousLocation: CLLocationCoordinate2D,
                                     swingType: SwingType) -> Bool {
        guard ignorePractice, swingType != .putt else { return false }
        let newLoc = CLLocation(latitude: newLocation.latitude, longitude: newLocation.longitude)
        let prevLoc = CLLocation(latitude: previousLocation.latitude, longitude: previousLocation.longitude)
        let distanceYards = newLoc.distance(from: prevLoc) * 1.09361
        let stillNearby = distanceYards <= ignorePracticeRadius
        let stillFew = stepsSinceLastDetectedSwing < stepGateThreshold
        return stillNearby && stillFew
    }

    func clearLastSwing() {
        lastDetectedSwing = nil
        dprint("⌚ [SwingDetection] Cleared last detected swing")
    }

    func cacheDetectionMetadata(strokeId: UUID, metadata: DetectionMetadata) {
        var updated = metadata
        updated.strokeId = strokeId
        detectionMetadataCache[strokeId] = updated
        detectionMotionCache[strokeId] = lastDetectionMotionSlice
        // Keep cache small — only last 5
        if detectionMetadataCache.count > 5 {
            let oldest = detectionMetadataCache.min { $0.value.timestamp < $1.value.timestamp }
            if let key = oldest?.key {
                detectionMetadataCache.removeValue(forKey: key)
                detectionMotionCache.removeValue(forKey: key)
            }
        }
    }

    func logUndoEvent(strokeId: UUID) {
        // Backend (Supabase) is the source of truth for swing diagnostics
        // now — `markFalsePositive(eventId:)` flips the row's label there.
        // We just clear the local caches so they don't grow indefinitely.
        detectionMetadataCache.removeValue(forKey: strokeId)
        detectionMotionCache.removeValue(forKey: strokeId)
    }

    /// Simulate a swing for testing in simulator
    func simulateSwing() {
        guard let location = LocationManager.latestDeviceLocation else {
            dprint("⌚ [SwingDetection] Cannot simulate swing - no location available")
            return
        }

        let swing = DetectedSwing(
            location: location.coordinate,
            timestamp: Date(),
            peakAcceleration: 3.5,
            trajectoryHeading: nil,
            swingType: .swing,
            fsPeakRotMag: 0, fsBsRatio: 0,
            bsTopPitch: 0, bsTopRoll: 0,
            preStrokePitch: 0, preStrokeRoll: 0,
            bsPeakRotX: 0, bsPeakRotY: 0, bsPeakRotZ: 0, bsPeakRotMag: 0,
            fsPeakRotX: 0, fsPeakRotY: 0, fsPeakRotZ: 0
        )

        DispatchQueue.main.async { self.lastDetectedSwing = swing }
        playFeedback()
        dprint("⌚ [SwingDetection] Simulated swing at \(location.coordinate)")
    }
}
