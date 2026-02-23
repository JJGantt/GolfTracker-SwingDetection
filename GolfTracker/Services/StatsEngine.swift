import Foundation
import CoreLocation

struct StatsEngine {

    // Outlier bounds for shot distance
    private static let minShotYards: Double = 5
    private static let maxShotYards: Double = 350

    // Deviation within this angle from ideal bearing = fairway hit
    private static let fairwayThresholdDegrees: Double = 15.0

    // MARK: - Main entry point

    static func compute(
        rounds: [Round],
        clubs: [ClubData],
        clubTypes: [ClubTypeData]
    ) -> PlayerStats {
        var stats = PlayerStats()
        stats.lastUpdated = Date()
        stats.totalRounds = rounds.count

        guard !rounds.isEmpty else { return stats }

        // Club lookup closures — local to avoid repeated param passing
        func clubData(for stroke: Stroke) -> ClubData? {
            clubs.first { $0.id == stroke.clubId }
        }
        func clubTypeData(for stroke: Stroke) -> ClubTypeData? {
            guard let c = clubData(for: stroke) else { return nil }
            return clubTypes.first { $0.id == c.clubTypeId }
        }
        func isPutt(_ stroke: Stroke) -> Bool {
            clubTypeData(for: stroke)?.name == "Putt"
        }

        // Accumulators
        var scoresVsPar: [Int] = []
        var puttCountsPerRound: [Int] = []
        var puttCountsPerHole: [Double] = []
        var girResults: [Bool] = []
        var fairwayResults: [Bool] = []
        var deviations: [Double] = []
        var clubTypeSamples: [UUID: [Double]] = [:]  // typeId → [yards]
        var clubSamples: [UUID: [Double]] = [:]       // clubId → [yards]

        for round in rounds {
            // Hole snapshot lookup for this round
            var holeByNumber: [Int: Hole] = [:]
            for hole in round.holes { holeByNumber[hole.number] = hole }

            // Round-level score vs par (only holes actually played)
            let playedHoleNumbers = Set(round.strokes.map { $0.holeNumber })
            let roundPar = round.holes
                .filter { playedHoleNumbers.contains($0.number) }
                .compactMap { $0.par }
                .reduce(0, +)
            let nonPenaltyTotal = round.strokes.filter { !$0.isPenalty }.count
            if roundPar > 0 {
                scoresVsPar.append(nonPenaltyTotal - roundPar)
                stats.totalRoundsWithPar += 1
            }

            // Per-hole stats
            let strokesByHole = Dictionary(grouping: round.strokes, by: { $0.holeNumber })
            var roundPutts = 0

            for (holeNumber, holeStrokes) in strokesByHole {
                guard let hole = holeByNumber[holeNumber] else { continue }
                let sorted = holeStrokes.sorted { $0.strokeNumber < $1.strokeNumber }
                let nonPenalty = sorted.filter { !$0.isPenalty }

                // Putts
                let putts = sorted.filter { isPutt($0) }
                roundPutts += putts.count
                puttCountsPerHole.append(Double(putts.count))

                // GIR: first putt stroke number <= par - 1
                if let par = hole.par,
                   let firstPutt = putts.min(by: { $0.strokeNumber < $1.strokeNumber }) {
                    girResults.append(firstPutt.strokeNumber <= par - 1)
                }

                // Fairway hit: par 4/5, tee shot has heading, hole has a coordinate
                if let par = hole.par, par >= 4,
                   let teeShot = nonPenalty.first,
                   let heading = teeShot.trajectoryHeading,
                   let holeCoord = hole.coordinate {
                    let idealBearing = MapCalculations.calculateBearing(from: teeShot.coordinate, to: holeCoord)
                    let deviation = angleDiff(heading, idealBearing)
                    fairwayResults.append(abs(deviation) <= fairwayThresholdDegrees)
                    deviations.append(abs(deviation))
                }

                // Shot distances: GPS delta between consecutive non-penalty strokes.
                // stroke[i].coordinate → stroke[i+1].coordinate is the distance travelled,
                // which equals the landing distance of shot i.
                for i in 0..<(nonPenalty.count - 1) {
                    let from = nonPenalty[i]
                    let to   = nonPenalty[i + 1]
                    let yards = metersToYards(
                        CLLocation(latitude: from.latitude, longitude: from.longitude)
                            .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
                    )
                    guard yards >= minShotYards && yards <= maxShotYards else { continue }

                    if let cId = clubData(for: from)?.id {
                        clubSamples[cId, default: []].append(yards)
                    }
                    if let tId = clubTypeData(for: from)?.id {
                        clubTypeSamples[tId, default: []].append(yards)
                    }
                }
            }

            puttCountsPerRound.append(roundPutts)
        }

        // MARK: Aggregate — scoring
        if !scoresVsPar.isEmpty {
            stats.avgScoreVsPar = Double(scoresVsPar.reduce(0, +)) / Double(scoresVsPar.count)
            stats.bestScoreVsPar = scoresVsPar.min()
        }
        if !puttCountsPerRound.isEmpty {
            stats.avgPuttsPerRound = Double(puttCountsPerRound.reduce(0, +)) / Double(puttCountsPerRound.count)
        }
        if !puttCountsPerHole.isEmpty {
            stats.avgPuttsPerHole = puttCountsPerHole.reduce(0, +) / Double(puttCountsPerHole.count)
        }
        if !girResults.isEmpty {
            stats.girPercent = Double(girResults.filter { $0 }.count) / Double(girResults.count) * 100
        }
        if !fairwayResults.isEmpty {
            stats.fairwayHitPercent = Double(fairwayResults.filter { $0 }.count) / Double(fairwayResults.count) * 100
        }
        if !deviations.isEmpty {
            stats.avgDeviationDegrees = deviations.reduce(0, +) / Double(deviations.count)
        }

        // MARK: Aggregate — per club type
        for (typeId, samples) in clubTypeSamples {
            guard let ct = clubTypes.first(where: { $0.id == typeId }) else { continue }
            stats.perClubTypeStats[typeId.uuidString] = makeDistanceStats(id: typeId, name: ct.name, samples: samples)
        }

        // MARK: Aggregate — per individual club
        for (clubId, samples) in clubSamples {
            guard let c = clubs.first(where: { $0.id == clubId }),
                  let ct = clubTypes.first(where: { $0.id == c.clubTypeId }) else { continue }
            let displayName = c.name == "Default" ? ct.name : "\(ct.name) – \(c.name)"
            stats.perClubStats[clubId.uuidString] = makeDistanceStats(id: clubId, name: displayName, samples: samples)
        }

        // MARK: Aggregate — per course
        let roundsByCourse = Dictionary(grouping: rounds, by: { $0.courseId })
        for (courseId, courseRounds) in roundsByCourse {
            let courseName = courseRounds.first?.courseName ?? "Unknown"
            var courseScores: [Int] = []
            for r in courseRounds {
                let pHoles = Set(r.strokes.map { $0.holeNumber })
                let par = r.holes.filter { pHoles.contains($0.number) }.compactMap { $0.par }.reduce(0, +)
                guard par > 0 else { continue }
                let strokes = r.strokes.filter { !$0.isPenalty }.count
                courseScores.append(strokes - par)
            }
            var cs = CourseStats(
                courseId: courseId,
                courseName: courseName,
                roundsPlayed: courseRounds.count,
                lastPlayed: courseRounds.map { $0.date }.max() ?? Date()
            )
            if !courseScores.isEmpty {
                cs.avgScoreVsPar = Double(courseScores.reduce(0, +)) / Double(courseScores.count)
                cs.bestScoreVsPar = courseScores.min()
                cs.worstScoreVsPar = courseScores.max()
            }
            stats.perCourseStats[courseId.uuidString] = cs
        }

        return stats
    }

    // MARK: - Distance stats helper

    private static func makeDistanceStats(id: UUID, name: String, samples: [Double]) -> ClubDistanceStats {
        let sorted = samples.sorted()
        let n = sorted.count
        let avg = sorted.reduce(0, +) / Double(n)
        let median: Double = n % 2 == 0
            ? (sorted[n/2 - 1] + sorted[n/2]) / 2.0
            : sorted[n/2]
        let variance = sorted.map { ($0 - avg) * ($0 - avg) }.reduce(0, +) / Double(n)
        let stdDev = sqrt(variance)

        // 10% trimmed mean — drop bottom and top 10% of samples before averaging
        let trimCount = max(0, Int((Double(n) * 0.1).rounded()))
        let trimmed = Array(sorted.dropFirst(trimCount).dropLast(trimCount))
        let trimmedAvg = trimmed.isEmpty ? avg : trimmed.reduce(0, +) / Double(trimmed.count)

        return ClubDistanceStats(
            id: id,
            name: name,
            sampleCount: n,
            avgDistanceYards: avg,
            trimmedAvgDistanceYards: trimmedAvg,
            medianDistanceYards: median,
            stdDevYards: stdDev,
            minYards: sorted.first ?? 0,
            maxYards: sorted.last ?? 0
        )
    }

    // MARK: - Geometry helpers

    private static func metersToYards(_ meters: Double) -> Double {
        meters * 1.09361
    }

    /// Signed angle difference A - B, normalized to -180...+180
    private static func angleDiff(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180  { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }
}
