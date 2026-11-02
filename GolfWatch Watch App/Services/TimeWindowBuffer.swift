import Foundation

/// Elements appended in time order, keeping only the last `duration` seconds
/// before the newest one.
///
/// Appending is amortised O(1): an expired element is passed over by moving
/// `start`, and the array is compacted only once the dead prefix is as long
/// as the live part, so each element is moved at most once more. (The 3-minute
/// motion buffer holds 18,000 samples at 100 Hz; removing the oldest from the
/// front of an array shifts all of them, on every sample.) Reading a window is
/// a binary search plus the window's own length.
///
/// Not thread-safe: callers hold their own lock.
struct TimeWindowBuffer<Element> {
    let duration: TimeInterval
    private let timeOf: (Element) -> TimeInterval
    private var storage: [Element] = []
    private var start = 0

    init(duration: TimeInterval, time: @escaping (Element) -> TimeInterval) {
        self.duration = duration
        self.timeOf = time
    }

    var count: Int { storage.count - start }
    var isEmpty: Bool { count == 0 }

    /// Everything held, oldest first.
    var elements: [Element] { Array(storage[start...]) }

    mutating func append(_ element: Element) {
        storage.append(element)
        let cutoff = timeOf(element) - duration
        while start < storage.count, timeOf(storage[start]) < cutoff {
            start += 1
        }
        if start > 0, start >= storage.count - start {
            storage.removeFirst(start)
            start = 0
        }
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        start = 0
    }

    /// The elements with times in `from...to`, oldest first.
    func elements(from: TimeInterval, to: TimeInterval) -> [Element] {
        guard from <= to else { return [] }
        var lo = start, hi = storage.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if timeOf(storage[mid]) < from { lo = mid + 1 } else { hi = mid }
        }
        var out: [Element] = []
        var i = lo
        while i < storage.count, timeOf(storage[i]) <= to {
            out.append(storage[i])
            i += 1
        }
        return out
    }
}
