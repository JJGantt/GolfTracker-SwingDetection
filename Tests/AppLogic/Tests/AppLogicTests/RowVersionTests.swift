import XCTest
@testable import AppLogic

/// How a device decides which copy of a synced row wins: by the server's
/// `updated_at`, read to the microsecond, with an older copy arriving later
/// dropped.
final class RowVersionTests: XCTestCase {

    /// Applies copies in arrival order the way `RealtimeSync` does, returning
    /// the payload left in place.
    private func deliver(_ copies: [(updatedAt: String?, payload: String)]) -> String? {
        var applied: (version: Int64?, payload: String)?
        for copy in copies {
            let incoming = copy.updatedAt.flatMap(RowVersion.parse)
            if RowVersion.isStale(incoming: incoming, applied: applied?.version) { continue }
            applied = (incoming ?? applied?.version, copy.payload)
        }
        return applied?.payload
    }

    func testAnOlderCopyArrivingAfterANewerOneIsDropped() {
        // The phone queued hole 3 for the watch; by the time it lands, the
        // watch has already applied hole 5.
        let result = deliver([("2026-11-01T14:03:09.500001+00:00", "hole 5"),
                              ("2026-11-01T14:03:09.500000+00:00", "hole 3")])
        XCTAssertEqual(result, "hole 5")
    }

    func testCopiesInOrderAllApply() {
        XCTAssertEqual(deliver([("2026-11-01T14:03:09+00:00", "a"),
                                ("2026-11-01T14:03:10+00:00", "b"),
                                ("2026-11-01T14:03:10+00:00", "b again")]), "b again")
    }

    func testACopyWithoutAVersionIsNeverDroppedAndKeepsTheLastVersion() {
        XCTAssertEqual(deliver([("2026-11-01T14:03:10Z", "versioned"), (nil, "legacy")]), "legacy")
        XCTAssertEqual(deliver([("2026-11-01T14:03:10Z", "new"), (nil, "legacy"),
                                ("2026-11-01T14:03:09Z", "old")]), "legacy")
    }

    func testPostgresTimestampFormsParseToTheSameInstant() {
        let expected: Int64 = 1_793_541_789_123_456   // 2026-11-01T14:03:09.123456Z
        for text in ["2026-11-01T14:03:09.123456+00:00",
                     "2026-11-01 14:03:09.123456+00",
                     "2026-11-01T14:03:09.123456Z",
                     "2026-11-01T10:03:09.123456-04:00",
                     "2026-11-01T19:33:09.123456+0530"] {
            XCTAssertEqual(RowVersion.parse(text), expected, text)
        }
    }

    func testFractionsShorterThanMicrosecondsAndNoneAtAll() {
        XCTAssertEqual(RowVersion.parse("1970-01-01T00:00:01.5+00:00"), 1_500_000)
        XCTAssertEqual(RowVersion.parse("1970-01-01T00:00:01+00:00"), 1_000_000)
        XCTAssertEqual(RowVersion.parse("2000-03-01T00:00:00Z"), 951_868_800_000_000)   // just past a leap day
    }

    func testMalformedTextIsNoVersion() {
        for text in ["", "2026-11-01", "2026-11-01T14:03:09", "2026-13-01T00:00:00Z",
                     "2026-11-01T14:03:09.+00:00", "2026-11-01T14:03:09+00:00 trailing"] {
            XCTAssertNil(RowVersion.parse(text), text)
        }
    }
}
