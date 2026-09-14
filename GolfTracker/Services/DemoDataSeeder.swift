import Foundation
import CoreLocation

/// Generates fake courses + rounds so the Stats / History / Round Detail screens
/// have something to render. Demo courses are tagged with a name prefix so they
/// can be wiped without touching real data.
enum DemoDataSeeder {
    static let demoPrefix = "[Demo] "

    struct GeneratedData {
        var courses: [Course]
        var rounds: [Round]
    }

    // MARK: - Public entry point

    static func generate(
        clubTypes: [ClubTypeData],
        availableClubs: [ClubData]
    ) -> GeneratedData {
        guard let clubsByTypeName = buildClubLookup(clubTypes: clubTypes, availableClubs: availableClubs) else {
            return GeneratedData(courses: [], rounds: [])
        }

        var rng = SeededGenerator(seed: 20260422)
        let courses = courseSpecs.map { buildCourse($0, rng: &rng) }

        var rounds: [Round] = []
        for spec in roundSpecs {
            let course = courses[spec.courseIndex]
            let round = buildRound(
                course: course,
                daysAgo: spec.daysAgo,
                skill: spec.skill,
                clubsByTypeName: clubsByTypeName,
                rng: &rng
            )
            rounds.append(round)
        }

        return GeneratedData(courses: courses, rounds: rounds)
    }

    // MARK: - Course catalog

    private struct CourseSpec {
        let name: String
        let center: CLLocationCoordinate2D
        let pars: [Int]            // 18 entries
        let rating: Double
        let slope: Int
        let city: String
    }

    private static let courseSpecs: [CourseSpec] = [
        CourseSpec(
            name: "Whispering Pines",
            center: CLLocationCoordinate2D(latitude: 30.2856, longitude: -81.7462),
            pars: [4, 5, 3, 4, 4, 5, 3, 4, 4, 4, 4, 3, 5, 4, 4, 3, 5, 4],
            rating: 71.2, slope: 128, city: "Jacksonville"
        ),
        CourseSpec(
            name: "Oak Hills CC",
            center: CLLocationCoordinate2D(latitude: 30.3405, longitude: -81.6557),
            pars: [4, 4, 5, 3, 4, 4, 3, 5, 4, 4, 3, 4, 4, 5, 3, 4, 5, 4],
            rating: 72.8, slope: 134, city: "Jacksonville"
        ),
        CourseSpec(
            name: "Sandy Cove Links",
            center: CLLocationCoordinate2D(latitude: 30.2030, longitude: -81.5550),
            pars: [4, 3, 5, 4, 4, 3, 4, 5, 4, 4, 4, 3, 5, 4, 3, 4, 5, 4],
            rating: 69.5, slope: 120, city: "Jacksonville Beach"
        )
    ]

    private struct RoundSpec {
        let courseIndex: Int
        let daysAgo: Int
        let skill: Double          // 0.0 = bad, 1.0 = scratch
    }

    // 10 rounds over ~3 months, trending slightly better
    private static let roundSpecs: [RoundSpec] = [
        RoundSpec(courseIndex: 0, daysAgo: 92, skill: 0.22),
        RoundSpec(courseIndex: 0, daysAgo: 81, skill: 0.26),
        RoundSpec(courseIndex: 1, daysAgo: 70, skill: 0.30),
        RoundSpec(courseIndex: 0, daysAgo: 58, skill: 0.33),
        RoundSpec(courseIndex: 2, daysAgo: 49, skill: 0.38),
        RoundSpec(courseIndex: 1, daysAgo: 40, skill: 0.41),
        RoundSpec(courseIndex: 0, daysAgo: 31, skill: 0.45),
        RoundSpec(courseIndex: 2, daysAgo: 21, skill: 0.49),
        RoundSpec(courseIndex: 1, daysAgo: 11, skill: 0.52),
        RoundSpec(courseIndex: 0, daysAgo: 3,  skill: 0.56)
    ]

    // MARK: - Course builder

    private static func buildCourse(_ spec: CourseSpec, rng: inout SeededGenerator) -> Course {
        var holes: [Hole] = []
        for i in 0..<spec.pars.count {
            let number = i + 1
            let par = spec.pars[i]

            // Arrange holes in a rough circle around the course center so bearings vary.
            let bearing = Double(i) * (360.0 / 18.0) + Double.random(in: -6...6, using: &rng)
            let distanceMeters = Double.random(in: 400...800, using: &rng)
            let coord = MapCalculations.calculateDestination(
                from: spec.center,
                bearing: bearing,
                distanceMeters: distanceMeters
            )
            holes.append(Hole(number: number, coordinate: coord, par: par))
        }

        return Course(
            id: UUID(),
            name: "\(demoPrefix)\(spec.name)",
            holes: holes,
            rating: spec.rating,
            slope: spec.slope,
            city: spec.city
        )
    }

    // MARK: - Round builder

    private static func buildRound(
        course: Course,
        daysAgo: Int,
        skill: Double,
        clubsByTypeName: [String: ClubData],
        rng: inout SeededGenerator
    ) -> Round {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let roundDate = calendar.date(byAdding: .day, value: -daysAgo, to: startOfToday)?
            .addingTimeInterval(TimeInterval(Int.random(in: 8...16, using: &rng)) * 3600)
            ?? Date()

        let roundId = UUID()
        var round = Round(
            id: roundId,
            courseId: course.id,
            courseName: course.name,
            holes: course.holes.oneByNumber.map { $0.roundCopy(roundId: roundId) },
            holeDetectionEnabled: false,
            locationTestModeEnabled: false
        )
        round.date = roundDate

        var completed = Set<Int>()
        var strokes: [Stroke] = []
        var strokeClock = roundDate

        for hole in course.holes {
            let result = buildHoleStrokes(
                hole: hole,
                skill: skill,
                startingClock: &strokeClock,
                clubsByTypeName: clubsByTypeName,
                rng: &rng
            )
            strokes.append(contentsOf: result)
            completed.insert(hole.number)
        }

        round.strokes = strokes
        round.completedHoles = completed
        round.currentHoleNumber = course.holes.map(\.number).max() ?? 1
        return round
    }

    // MARK: - Hole builder

    private static func buildHoleStrokes(
        hole: Hole,
        skill: Double,
        startingClock: inout Date,
        clubsByTypeName: [String: ClubData],
        rng: inout SeededGenerator
    ) -> [Stroke] {
        guard let holeCoord = hole.coordinate,
              let par = hole.par,
              let putterId = clubsByTypeName["Putt"]?.id else {
            return []
        }

        // Expected hole length in yards
        let holeYards: Double
        switch par {
        case 3: holeYards = Double.random(in: 140...205, using: &rng)
        case 5: holeYards = Double.random(in: 470...560, using: &rng)
        default: holeYards = Double.random(in: 310...430, using: &rng)  // par 4
        }

        // Tee coord = hole coord projected backward along a random bearing
        let approachBearing = Double.random(in: 0..<360, using: &rng)
        let holeMeters = holeYards / 1.09361
        let teeCoord = MapCalculations.calculateDestination(
            from: holeCoord,
            bearing: (approachBearing + 180).truncatingRemainder(dividingBy: 360),
            distanceMeters: holeMeters
        )

        // Decide total strokes for the hole
        let scoreDiff = sampleScoreDiff(par: par, skill: skill, rng: &rng)
        let totalStrokes = max(par - 1, par + scoreDiff)  // allow occasional eagle

        // Decide number of putts (usually 2, trending lower with higher skill)
        let putts = samplePuttCount(skill: skill, rng: &rng)
        let teeToGreen = max(1, totalStrokes - putts)

        var result: [Stroke] = []
        var currentCoord = teeCoord
        var remainingYards = holeYards

        for shotIndex in 0..<teeToGreen {
            let isFirst = (shotIndex == 0)
            let isLast = (shotIndex == teeToGreen - 1)

            // Plan distance for this shot
            let plannedYards: Double = {
                if isLast {
                    // Land on/near the green
                    return max(20, remainingYards - Double.random(in: 5...15, using: &rng))
                }
                // Distribute remaining distance; first shot on par 4/5 is a full driver
                if isFirst && par >= 4 {
                    return min(remainingYards - 60, Double.random(in: 220...260, using: &rng))
                }
                let avg = remainingYards / Double(teeToGreen - shotIndex)
                return max(40, avg + Double.random(in: -15...15, using: &rng))
            }()

            let clubType = pickClubType(
                forYards: plannedYards,
                isTeeShot: isFirst && par >= 4,
                clubsByTypeName: clubsByTypeName
            )
            let clubId = clubsByTypeName[clubType]?.id ?? clubsByTypeName["7-Iron"]?.id ?? putterId

            // Trajectory heading: only first-shot on par 4/5 (that's what fairway stat uses)
            let trajectory: Double? = {
                guard isFirst, par >= 4 else { return nil }
                let ideal = MapCalculations.calculateBearing(from: currentCoord, to: holeCoord)
                // Skill ↑ = deviation ↓
                let deviationRange: Double = skill < 0.30 ? 28 : (skill < 0.45 ? 18 : 11)
                let deviation = Double.random(in: -deviationRange...deviationRange, using: &rng)
                return (ideal + deviation + 360).truncatingRemainder(dividingBy: 360)
            }()

            let strokeNumber = result.count + 1
            var stroke = Stroke(
                holeNumber: hole.number,
                strokeNumber: strokeNumber,
                coordinate: currentCoord,
                clubId: clubId,
                trajectoryHeading: trajectory
            )
            stroke.timestamp = startingClock
            result.append(stroke)

            // Advance to next position (bearing to hole + small lateral noise)
            let bearingToHole = MapCalculations.calculateBearing(from: currentCoord, to: holeCoord)
            let lateralNoise = Double.random(in: -6...6, using: &rng)
            let shotMeters = plannedYards / 1.09361
            currentCoord = MapCalculations.calculateDestination(
                from: currentCoord,
                bearing: (bearingToHole + lateralNoise + 360).truncatingRemainder(dividingBy: 360),
                distanceMeters: shotMeters
            )
            remainingYards = max(0, remainingYards - plannedYards)
            startingClock = startingClock.addingTimeInterval(Double.random(in: 90...220, using: &rng))
        }

        // Putts — place on green, each halving distance to the cup
        for p in 0..<putts {
            let strokeNumber = result.count + 1
            var stroke = Stroke(
                holeNumber: hole.number,
                strokeNumber: strokeNumber,
                coordinate: currentCoord,
                clubId: putterId,
                trajectoryHeading: nil
            )
            stroke.timestamp = startingClock
            result.append(stroke)

            // Advance halfway to hole unless this is the last putt
            if p < putts - 1 {
                let bearingToHole = MapCalculations.calculateBearing(from: currentCoord, to: holeCoord)
                let remainingMeters = CLLocation(latitude: currentCoord.latitude, longitude: currentCoord.longitude)
                    .distance(from: CLLocation(latitude: holeCoord.latitude, longitude: holeCoord.longitude))
                let advanceMeters = remainingMeters * Double.random(in: 0.55...0.8, using: &rng)
                currentCoord = MapCalculations.calculateDestination(
                    from: currentCoord,
                    bearing: bearingToHole,
                    distanceMeters: advanceMeters
                )
            }
            startingClock = startingClock.addingTimeInterval(Double.random(in: 30...90, using: &rng))
        }

        return result
    }

    // MARK: - Sampling helpers

    /// Produce a realistic score-vs-par for a single hole given a skill value.
    private static func sampleScoreDiff(par: Int, skill: Double, rng: inout SeededGenerator) -> Int {
        // Weighted distribution; better skill shifts probability toward 0 / -1.
        // (diff : weight)
        let weights: [(Int, Double)]
        if skill < 0.30 {
            weights = [(-1, 0.02), (0, 0.25), (1, 0.40), (2, 0.25), (3, 0.08)]
        } else if skill < 0.45 {
            weights = [(-1, 0.05), (0, 0.40), (1, 0.35), (2, 0.15), (3, 0.05)]
        } else {
            weights = [(-1, 0.08), (0, 0.55), (1, 0.25), (2, 0.10), (3, 0.02)]
        }
        let roll = Double.random(in: 0..<1, using: &rng)
        var cumulative = 0.0
        for (diff, weight) in weights {
            cumulative += weight
            if roll <= cumulative { return diff }
        }
        return 0
    }

    private static func samplePuttCount(skill: Double, rng: inout SeededGenerator) -> Int {
        let roll = Double.random(in: 0..<1, using: &rng)
        if skill < 0.30 {
            if roll < 0.10 { return 1 }
            if roll < 0.75 { return 2 }
            return 3
        } else if skill < 0.45 {
            if roll < 0.18 { return 1 }
            if roll < 0.88 { return 2 }
            return 3
        } else {
            if roll < 0.28 { return 1 }
            if roll < 0.94 { return 2 }
            return 3
        }
    }

    // MARK: - Club selection

    /// Priority order of club types to consider, closest to longest.
    private static let clubLadder: [(name: String, yards: Double)] = [
        ("Drive", 245), ("3-Wood", 225), ("5-Wood", 207),
        ("4-Hyb", 192), ("5-Hyb", 180),
        ("4-Iron", 170), ("5-Iron", 160), ("6-Iron", 150),
        ("7-Iron", 140), ("8-Iron", 130), ("9-Iron", 118),
        ("Pitch", 106), ("Gap", 93), ("Sand", 78), ("Lob", 45)
    ]

    private static func pickClubType(
        forYards yards: Double,
        isTeeShot: Bool,
        clubsByTypeName: [String: ClubData]
    ) -> String {
        if isTeeShot, clubsByTypeName["Drive"] != nil { return "Drive" }
        // Find the ladder entry whose avg yardage is closest.
        var best = clubLadder.first!
        var bestDelta = abs(best.yards - yards)
        for entry in clubLadder {
            guard clubsByTypeName[entry.name] != nil else { continue }
            let delta = abs(entry.yards - yards)
            if delta < bestDelta {
                best = entry
                bestDelta = delta
            }
        }
        return best.name
    }

    // MARK: - Lookup

    private static func buildClubLookup(
        clubTypes: [ClubTypeData],
        availableClubs: [ClubData]
    ) -> [String: ClubData]? {
        var map: [String: ClubData] = [:]
        for type in clubTypes {
            // Prefer the default club for this type; fall back to any club of this type.
            let club = availableClubs.first(where: { $0.clubTypeId == type.id && $0.isDefault })
                    ?? availableClubs.first(where: { $0.clubTypeId == type.id })
            if let club { map[type.name] = club }
        }
        return map.isEmpty ? nil : map
    }
}

// MARK: - Seeded RNG

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed == 0 ? 0xdeadbeef : seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
