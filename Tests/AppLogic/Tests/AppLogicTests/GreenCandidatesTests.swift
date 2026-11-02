import XCTest
@testable import AppLogic

/// Which greens a course offers on the map and in the green-placement picker:
/// every mapped OSM green, then the detector's blobs that survive the user's
/// filters, best first and capped.
final class GreenCandidatesTests: XCTestCase {

    private func blob(score: Int, area: Int = 500, width: Double = 10, elongation: Double = 2) -> HoleDetectionBlob {
        HoleDetectionBlob(area: area, minWidth: width, elongation: elongation, greennessScore: score,
                          centroidLatitude: 30, centroidLongitude: -81, polygon: [])
    }
    private func detection(_ blobs: [HoleDetectionBlob]) -> CourseHoleDetectionData {
        CourseHoleDetectionData(courseId: UUID(), generatedAt: Date(), blobs: blobs)
    }
    private let square = [MapPoint(latitude: 0, longitude: 0), MapPoint(latitude: 0, longitude: 2),
                          MapPoint(latitude: 2, longitude: 2), MapPoint(latitude: 2, longitude: 0)]

    func testOSMGreensComeFirstCentredOnTheirVerticesAndSurviveAnyFilter() {
        var strict = HoleDetectionFilterSettings.default
        strict.minArea = 5_000
        strict.maxRank = 1
        let list = GreenCandidates.list(osmGreens: [square, square], detection: detection([blob(score: 50)]), filter: strict)
        XCTAssertEqual(list.count, 2)                       // the detector blob fails minArea
        XCTAssertEqual(list[0].centroidLatitude, 1)
        XCTAssertEqual(list[0].centroidLongitude, 1)
        XCTAssertEqual(list[0].polygon, square)
        XCTAssertTrue(list[0].passesShapeFilter(strict))
        XCTAssertNotEqual(list[0].id, list[1].id)
    }

    func testDetectorBlobsAreShapeFilteredThenRankedByScoreAndCapped() {
        var f = HoleDetectionFilterSettings.default
        f.minWidth = 5
        f.maxElongation = 4
        f.minGreennessScore = 20
        f.maxRank = 2
        let kept = GreenCandidates.list(osmGreens: nil, detection: detection([
            blob(score: 30), blob(score: 90), blob(score: 60),
            blob(score: 99, width: 3),          // too narrow
            blob(score: 98, elongation: 6),     // too elongated
            blob(score: 10),                    // below score
        ]), filter: f)
        XCTAssertEqual(kept.map(\.greennessScore), [90, 60])
    }

    func testFilterOffPassesTheDetectorOutputUnchanged() {
        var f = HoleDetectionFilterSettings.default
        f.enabled = false
        f.minArea = 1_000_000
        let blobs = [blob(score: 1), blob(score: 3), blob(score: 2)]
        XCTAssertEqual(GreenCandidates.list(osmGreens: nil, detection: detection(blobs), filter: f), blobs)
    }

    func testNothingKnownIsNoCandidates() {
        XCTAssertEqual(GreenCandidates.list(osmGreens: nil, detection: nil, filter: .default), [])
    }
}
