import XCTest
@testable import AppLogic

/// What the watch's rolling motion buffer holds: exactly the last `duration`
/// seconds, in order, with windows read out by time.
final class TimeWindowBufferTests: XCTestCase {

    private func buffer(_ duration: TimeInterval) -> TimeWindowBuffer<Double> {
        TimeWindowBuffer(duration: duration) { $0 }
    }

    func testKeepsOnlyTheLastDurationAt100Hz() {
        var b = buffer(180)
        let times = (0..<60_000).map { Double($0) / 100 }      // 600 s of samples
        for t in times { b.append(t) }
        let newest = times.last!
        XCTAssertEqual(b.elements, times.filter { $0 >= newest - 180 })
        XCTAssertEqual(b.count, 18_001, accuracy: 1)
    }

    func testWindowReadsAreInclusiveAndInOrder() {
        var b = buffer(10)
        for t in stride(from: 0.0, through: 5.0, by: 0.5) { b.append(t) }
        XCTAssertEqual(b.elements(from: 1.0, to: 2.0), [1.0, 1.5, 2.0])
        XCTAssertEqual(b.elements(from: 1.2, to: 1.4), [])
        XCTAssertEqual(b.elements(from: -5, to: 0.5), [0.0, 0.5])
        XCTAssertEqual(b.elements(from: 4.9, to: 99), [5.0])
        XCTAssertEqual(b.elements(from: 3, to: 2), [])
    }

    func testWindowReadsNeverReturnExpiredSamples() {
        var b = buffer(1)
        for t in stride(from: 0.0, through: 10.0, by: 0.25) { b.append(t) }
        XCTAssertEqual(b.elements(from: 0, to: 10), [9.0, 9.25, 9.5, 9.75, 10.0])
    }

    func testRemoveAllEmptiesAndTheBufferRefills() {
        var b = buffer(1)
        for t in [0.0, 0.5, 1.0] { b.append(t) }
        b.removeAll()
        XCTAssertTrue(b.isEmpty)
        XCTAssertEqual(b.elements(from: 0, to: 1), [])
        b.append(100)
        XCTAssertEqual(b.elements, [100])
    }
}
