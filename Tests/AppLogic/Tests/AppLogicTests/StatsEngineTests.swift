import XCTest
import CoreLocation
import SwiftData
@testable import AppLogic

/// What `StatsEngine.compute` makes of rounds: which holes and rounds count
/// toward scoring, the score, putts and GIR it derives, and the club distances
/// it measures between shots.
final class StatsEngineTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var putter: ClubData!
    private var driver: ClubData!
    private var clubTypes: [ClubTypeData] = []

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: ClubTypeData.self, ClubData.self, ClubSet.self, Course.self, Hole.self,
            Stroke.self, Target.self, Round.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        let puttType = ClubTypeData(name: "Putt", isDefault: true)
        let driveType = ClubTypeData(name: "Drive", isDefault: true)
        clubTypes = [puttType, driveType]
        putter = ClubData(name: "Default", clubTypeId: puttType.id)
        driver = ClubData(name: "Default", clubTypeId: driveType.id)
        for m in [puttType, driveType] { context.insert(m) }
        for m in [putter!, driver!] { context.insert(m) }
    }

    // MARK: - Building rounds

    private static let origin = CLLocationCoordinate2D(latitude: 30, longitude: -81)
    /// A point `yards` north of the origin.
    private static func north(_ yards: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: origin.latitude + yards / 1.09361 / 111_195, longitude: origin.longitude)
    }

    private func course(pars: [Int]) -> Course {
        let c = Course(name: "Test")
        context.insert(c)
        for (i, par) in pars.enumerated() {
            let h = Hole(number: i + 1, par: par)
            context.insert(h)
            c.holes.append(h)
        }
        return c
    }

    /// One shot: a club and a position in yards along the hole.
    private enum Shot { case drive(Double), putt(Double), penalty(Double) }

    private func round(at course: Course, holes: [[Shot]]) -> Round {
        let r = Round(courseId: course.id, courseName: course.name)
        context.insert(r)
        for (i, shots) in holes.enumerated() {
            for (n, shot) in shots.enumerated() {
                let s: Stroke
                switch shot {
                case .drive(let y):
                    s = Stroke(holeNumber: i + 1, strokeNumber: n + 1, coordinate: Self.north(y), clubId: driver.id)
                case .putt(let y):
                    s = Stroke(holeNumber: i + 1, strokeNumber: n + 1, coordinate: Self.north(y), clubId: putter.id)
                case .penalty(let y):
                    s = Stroke(holeNumber: i + 1, strokeNumber: n + 1, coordinate: Self.north(y),
                               clubId: driver.id, isPenalty: true)
                }
                context.insert(s)
                r.strokes.append(s)
            }
        }
        return r
    }

    private func compute(_ rounds: [Round], courses: [Course]) -> PlayerStats {
        StatsEngine.compute(rounds: rounds, courses: courses, clubs: [putter, driver], clubTypes: clubTypes)
    }

    /// A par-4 played as drive, approach, two putts.
    private let parHole: [Shot] = [.drive(0), .drive(250), .putt(395), .putt(399)]

    // MARK: - Scoring

    func testEighteenHolesAtParScoreLevelWithTwoPuttsAndEveryGreenInRegulation() {
        let c = course(pars: Array(repeating: 4, count: 18))
        let stats = compute([round(at: c, holes: Array(repeating: parHole, count: 18))], courses: [c])
        XCTAssertEqual(stats.scoring18.roundCount, 1)
        XCTAssertEqual(stats.scoring18.avgScoreVsPar, 0)
        XCTAssertEqual(stats.scoring18.avgPuttsPerRound, 36)
        XCTAssertEqual(stats.avgPuttsPerHole, 2)
        XCTAssertEqual(stats.girPercent, 100)
        XCTAssertTrue(stats.scoring9.isEmpty)
    }

    func testNineHoleRoundsScoreSeparatelyFromEighteen() {
        let c = course(pars: Array(repeating: 4, count: 9))
        var holes = Array(repeating: parHole, count: 9)
        holes[0] = [.drive(0), .drive(250), .drive(380), .putt(395), .putt(399)]   // a bogey
        let stats = compute([round(at: c, holes: holes)], courses: [c])
        XCTAssertEqual(stats.scoring9.roundCount, 1)
        XCTAssertEqual(stats.scoring9.avgScoreVsPar, 1)
        XCTAssertTrue(stats.scoring18.isEmpty)
    }

    func testAHoleWithOneStrokeIsNotPlayedSoTheRoundIsAPartial() {
        let c = course(pars: Array(repeating: 4, count: 18))
        var holes = Array(repeating: parHole, count: 18)
        holes[17] = [.drive(0)]
        let stats = compute([round(at: c, holes: holes)], courses: [c])
        XCTAssertTrue(stats.scoring18.isEmpty)
        XCTAssertNil(stats.girPercent)
        XCTAssertEqual(stats.perCourseStats[c.id.uuidString]?.roundsPlayed, 1)
        XCTAssertEqual(stats.perCourseStats[c.id.uuidString]?.scoredRounds, 0)
    }

    func testParsComeFromTheCourseNotTheRound() {
        let c = course(pars: Array(repeating: 5, count: 9))
        let r = round(at: c, holes: Array(repeating: parHole, count: 9))
        r.holes = (1...9).map { Hole(number: $0, par: 3) }
        let stats = compute([r], courses: [c])
        XCTAssertEqual(stats.scoring9.avgScoreVsPar, -9)
    }

    func testPerHoleHistoryAtACourseAveragesAcrossRounds() {
        let c = course(pars: Array(repeating: 4, count: 9))
        var bogeyFirst = Array(repeating: parHole, count: 9)
        bogeyFirst[0] = [.drive(0), .drive(250), .drive(380), .putt(395), .putt(399)]
        let stats = compute([round(at: c, holes: Array(repeating: parHole, count: 9)),
                             round(at: c, holes: bogeyFirst)], courses: [c])
        let hole1 = stats.perCourseStats[c.id.uuidString]?.holeStats[1]
        XCTAssertEqual(hole1?.timesPlayed, 2)
        XCTAssertEqual(hole1?.avgStrokes, 4.5)
        XCTAssertEqual(hole1?.avgPutts, 2)
        XCTAssertEqual(stats.perCourseStats[c.id.uuidString]?.worstScoreVsPar, 1)
    }

    // MARK: - Penalties

    /// Two penalty strokes and nothing else: the hole has two strokes, so it
    /// counts, and there is no shot to measure a distance from.
    func testAHoleOfOnlyPenaltyStrokesComputesWithoutAShot() {
        let c = course(pars: Array(repeating: 4, count: 9))
        var holes = Array(repeating: parHole, count: 9)
        holes[4] = [.penalty(0), .penalty(10)]
        let stats = compute([round(at: c, holes: holes)], courses: [c])
        XCTAssertEqual(stats.scoring9.roundCount, 1)
        XCTAssertEqual(stats.perCourseStats[c.id.uuidString]?.holeStats[5]?.avgStrokes, 0)
    }

    // MARK: - Club distances

    func testShotDistanceIsMeasuredToTheNextRealShotSkippingPenalties() throws {
        let c = course(pars: [4])
        let stats = compute([round(at: c, holes: [[.drive(0), .penalty(100), .drive(240), .putt(400)]])], courses: [c])
        let drives = try XCTUnwrap(stats.perClubStats[driver.id.uuidString])
        XCTAssertEqual(drives.sampleCount, 2)            // 0→240 and 240→400; the penalty is not a shot
        XCTAssertEqual(drives.minYards, 160, accuracy: 2)
        XCTAssertEqual(drives.maxYards, 240, accuracy: 2)
        XCTAssertEqual(stats.perClubTypeStats[clubTypes[1].id.uuidString]?.sampleCount, 2)
    }

    func testImplausibleDistancesAreDropped() {
        let c = course(pars: [4])
        // 2 yd (a re-tap) and 500 yd (GPS jump) are out of range; 150 is kept.
        let stats = compute([round(at: c, holes: [[.drive(0), .drive(2), .drive(502), .drive(652)]])], courses: [c])
        XCTAssertEqual(stats.perClubStats[driver.id.uuidString]?.sampleCount, 1)
    }

    func testPartialRoundsStillContributeDistances() {
        let c = course(pars: [4, 4])
        let stats = compute([round(at: c, holes: [[.drive(0), .drive(200)], [.drive(0)]])], courses: [c])
        XCTAssertTrue(stats.scoring9.isEmpty && stats.scoring18.isEmpty)
        XCTAssertEqual(stats.perClubStats[driver.id.uuidString]?.sampleCount, 1)
    }
}
