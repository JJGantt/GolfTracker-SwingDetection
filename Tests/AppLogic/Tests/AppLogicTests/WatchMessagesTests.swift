import XCTest
@testable import AppLogic

/// The phone and the watch update separately, so each may be talking to an
/// older build of the other. These pin the dictionaries every WatchConnectivity
/// message and context entry travels as: what a new build sends must be what
/// an older build reads, and what an older build sends must read.
final class WatchMessagesTests: XCTestCase {

    private let courseId = UUID(uuidString: "6F1D2B3C-4A5B-4C6D-8E7F-901234567890")!

    /// A dictionary as the other device receives it: through a binary plist,
    /// which is how WatchConnectivity carries it.
    private func wire(_ d: [String: Any]) -> [String: Any] {
        let data = try! PropertyListSerialization.data(fromPropertyList: d, format: .binary, options: 0)
        return try! PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
    }

    private func assertSame(_ a: [String: Any], _ b: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(NSDictionary(dictionary: a), NSDictionary(dictionary: b), file: file, line: line)
    }

    // MARK: - What a new build sends

    func testMessagesSendTheDictionariesOlderBuildsRead() {
        let data = Data([1, 2, 3])
        assertSame(WatchMessage.holeDetectionData(data).dictionary, ["type": "holeDetectionData", "data": data])
        assertSame(WatchMessage.holeFilterSettings(data).dictionary, ["type": "holeFilterSettings", "data": data])
        assertSame(WatchMessage.authSession(Data()).dictionary, ["type": "authSession", "data": Data()])
        assertSame(WatchMessage.requestAuthSession.dictionary, ["type": "requestAuthSession"])
        assertSame(WatchMessage.clientEventLoggerEnabled(true).dictionary, ["type": "clientEventLoggerEnabled", "value": true])
        assertSame(WatchMessage.devParam(["autoAdd": false]).dictionary, ["type": "devParam", "autoAdd": false])
        assertSame(WatchMessage.watchLog("hi").dictionary, ["type": "watchLog", "msg": "hi"])
        assertSame(WatchMessage.holeDetectionRequest(HoleDetectionRequest(courseId: courseId, at: 1_762_000_000.25)).dictionary,
                   ["type": "holeDetectionRequest", "courseId": courseId.uuidString, "at": 1_762_000_000.25])
        assertSame(WatchMessage.holeDetectionStatus(HoleDetectionStatusUpdate(courseId: courseId, state: .queued, at: 5)).dictionary,
                   ["type": "holeDetectionStatus", "courseId": courseId.uuidString, "state": "queued", "at": 5.0])
        assertSame(WatchMessage.roundRow(RoundRowRelay(table: "strokes", kind: "update", record: data)).dictionary,
                   ["type": "roundRow", "table": "strokes", "kind": "update", "record": data])
        assertSame(WatchMessage.testModeState(TestModeState(enabled: true, lat: 30.5, lon: -81.25)).dictionary,
                   ["type": "testModeState", "enabled": true, "lat": 30.5, "lon": -81.25])
    }

    func testContextPayloadsCarryNoTypeAndLeaveOutAbsentFields() {
        assertSame(TestModeState(enabled: false, lat: nil, lon: nil).dictionary, ["enabled": false])
        assertSame(HoleDetectionRequest(courseId: courseId, at: 7).dictionary,
                   ["courseId": courseId.uuidString, "at": 7.0])
    }

    /// The phone dedupes a request on `at` by equality, so it must arrive as
    /// exactly the Double that was sent.
    func testRequestTimeSurvivesTheWireExactly() {
        let at = Date().timeIntervalSince1970
        let sent = WatchMessage.holeDetectionRequest(HoleDetectionRequest(courseId: courseId, at: at)).dictionary
        XCTAssertEqual(wire(sent)["at"] as? Double, at)
        guard case .holeDetectionRequest(let r) = WatchMessage(wire(sent)) else { return XCTFail() }
        XCTAssertEqual(r.at, at)
    }

    // MARK: - What an older build sends

    func testOlderBuildsMessagesRead() {
        let data = Data([9])
        guard case .roundRow(let row) = WatchMessage(wire(["type": "roundRow", "table": "holes", "kind": "insert", "record": data]))
        else { return XCTFail() }
        XCTAssertEqual(row, RoundRowRelay(table: "holes", kind: "insert", record: data))

        guard case .holeDetectionStatus(let s) = WatchMessage(wire(["type": "holeDetectionStatus", "courseId": courseId.uuidString,
                                                                    "state": "done", "at": 12.5]))
        else { return XCTFail() }
        XCTAssertEqual(s, HoleDetectionStatusUpdate(courseId: courseId, state: .done, at: 12.5))

        guard case .devParam(let p) = WatchMessage(wire(["type": "devParam", "ignorePracticeRadius": 12.0])) else { return XCTFail() }
        XCTAssertEqual(p as NSDictionary, ["ignorePracticeRadius": 12.0] as NSDictionary)

        guard case .authSession(let d) = WatchMessage(wire(["type": "authSession", "data": Data()])) else { return XCTFail() }
        XCTAssertTrue(d.isEmpty)
    }

    func testOptionalFieldsMayBeMissing() {
        // A request with no `at` still names its course; the phone runs it
        // without the duplicate check.
        XCTAssertEqual(HoleDetectionRequest(dictionary: wire(["courseId": courseId.uuidString])),
                       HoleDetectionRequest(courseId: courseId, at: nil))
        // Test mode with no `enabled` is off.
        XCTAssertEqual(TestModeState(dictionary: wire(["lat": 1.0])), TestModeState(enabled: false, lat: 1.0, lon: nil))
    }

    func testUnreadableMessagesAreDropped() {
        XCTAssertNil(WatchMessage(["type": "somethingNewer", "x": 1]))
        XCTAssertNil(WatchMessage(["data": Data()]))
        XCTAssertNil(WatchMessage(wire(["type": "holeDetectionStatus", "courseId": "not-a-uuid", "state": "done"])))
        XCTAssertNil(WatchMessage(wire(["type": "holeDetectionStatus", "courseId": courseId.uuidString, "state": "paused"])))
        XCTAssertNil(WatchMessage(wire(["type": "roundRow", "table": "holes", "kind": "insert"])))
    }
}
