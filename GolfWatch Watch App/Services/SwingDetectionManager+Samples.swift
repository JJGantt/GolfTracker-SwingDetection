import Foundation

// Motion samples kept for upload, and the 800Hz ring they are sliced from.
extension SwingDetectionManager {

    struct RecordedDataPoint: Codable {
        let sensorTime: TimeInterval
        let userAccelX: Double
        let userAccelY: Double
        let userAccelZ: Double
        let userAccelMag: Double
        let rotationX: Double
        let rotationY: Double
        let rotationZ: Double
        let rotationMag: Double
        let gravityX: Double
        let gravityY: Double
        let gravityZ: Double
        let pitch: Double
        let roll: Double
        let yaw: Double
        // CMMagneticField.accuracy at this sample. Used downstream to filter
        // swings whose magnetometer-anchored attitude can't be trusted (e.g.
        // metallic interference, uncalibrated cold start). Values:
        //   -1 = uncalibrated (sensor not yet usable)
        //    0 = low      (large error possible)
        //    1 = medium
        //    2 = high     (best quality)
        let magAccuracy: Int
    }

    // Raw accelerometer data point (high frequency, only during recording)
    struct RawAccelDataPoint: Codable {
        let sensorTime: TimeInterval
        let rawAccelX: Double
        let rawAccelY: Double
        let rawAccelZ: Double
        let rawAccelMag: Double
    }

    /// Fixed-capacity time-ordered ring buffer for high-rate raw accel samples.
    struct RawAccelRingBuffer {
        private var storage: [RawAccelDataPoint?]
        private var head: Int = 0
        private(set) var count: Int = 0

        init(capacity: Int) {
            let cap = max(1, capacity)
            storage = Array(repeating: nil, count: cap)
        }

        mutating func clear() {
            head = 0
            count = 0
        }

        mutating func append(_ sample: RawAccelDataPoint) {
            storage[head] = sample
            head = (head + 1) % storage.count
            if count < storage.count {
                count += 1
            }
        }

        mutating func trim(olderThan cutoff: TimeInterval) {
            while count > 0 {
                let oldestIndex = (head - count + storage.count) % storage.count
                guard let oldest = storage[oldestIndex] else {
                    count -= 1
                    continue
                }
                if oldest.sensorTime < cutoff {
                    storage[oldestIndex] = nil
                    count -= 1
                } else {
                    break
                }
            }
            if count == 0 {
                head = 0
            }
        }

        func samples(in range: ClosedRange<TimeInterval>) -> [RawAccelDataPoint] {
            guard count > 0 else { return [] }
            var out: [RawAccelDataPoint] = []
            out.reserveCapacity(min(count, 512))
            for offset in 0..<count {
                let idx = (head - count + offset + storage.count) % storage.count
                guard let sample = storage[idx] else { continue }
                let t = sample.sensorTime
                if t < range.lowerBound {
                    continue
                }
                if t > range.upperBound {
                    break
                }
                out.append(sample)
            }
            return out
        }
    }
}
