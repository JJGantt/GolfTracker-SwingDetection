import Foundation
import CoreLocation

struct StatsEngine {

    // Outlier bounds for shot distance
    private static let minShotYards: Double = 5
    private static let maxShotYards: Double = 350

    /// Minimum strokes on a hole for it to count as played. One stroke means
    /// teed off and walked away — charging the hole's full par for that is
    /// what produced impossible negative scores (a single drive on a par 5
    /// scored −4, and a two-hole session scored −6).
    private static let minStrokesPerHole = 2

    /// A round only enters scoring stats when its counted holes add up to a
    /// real round length. Anything else is a partial: it stays in History but
    /// never averages against real golf. This also self-cleans rounds where
    /// strokes went unrecorded — an 18-hole round missing strokes on one hole
    /// lands on 17 counted holes and drops out on its own, no threshold
    /// tuning required.
    private static let scoredHoleCounts: Set<Int> = [9, 18]

    // MARK: - Qualification

    /// One hole's worth of play, already filtered to holes with real strokes.
    private struct CountedHole {
        let number: Int
        let par: Int
        let strokes: [Stroke]          // sorted by strokeNumber, penalties included
        let nonPenalty: [Stroke]
    }

    /// The holes on `round` that had real play, resolved against `holesByNumber`.
    ///
    /// Callers must pass holes resolved via the round's COURSE, not
    /// `round.holes` — `Hole.round` is to-one, so older rounds' `holes` arrays
    /// drain as newer rounds at the same course adopt the shared instances.
    /// Reading `round.holes` here silently zeroed the par for every round but
    /// the most recent one per course.
    private static func countedHoles(in round: Round,
                                     holesByNumber: [Int: Hole]) -> [CountedHole] {
        Dictionary(grouping: round.strokes, by: { $0.holeNumber })
            .compactMap { holeNumber, holeStrokes -> CountedHole? in
                guard holeStrokes.count >= minStrokesPerHole,
                      let par = holesByNumber[holeNumber]?.par else { return nil }
                let sorted = holeStrokes.sorted { $0.strokeNumber < $1.strokeNumber }
                return CountedHole(
                    number: holeNumber,
                    par: par,
                    strokes: sorted,
                    nonPenalty: sorted.filter { !$0.isPenalty }
                )
            }
            .sorted { $0.number < $1.number }
    }

    // MARK: - Main entry point

    /// - Parameter courses: needed to resolve each round's holes by `courseId`.
    ///   See `countedHoles` for why `round.holes` can't be trusted here.
    static func compute(
        rounds: [Round],
        courses: [Course],
        clubs: [ClubData],
        clubTypes: [ClubTypeData]
    ) -> PlayerStats {
        var stats = PlayerStats()
        stats.lastUpdated = Date()
        stats.totalRounds = rounds.count

        guard !rounds.isEmpty else { return stats }

        // Hole lookup per course — the durable source for pars.
        var holesByCourse: [UUID: [Int: Hole]] = [:]
        for course in courses {
            var byNumber: [Int: Hole] = [:]
            for hole in course.holes { byNumber[hole.number] = hole }
            holesByCourse[course.id] = byNumber
        }
        /// Course holes when we have them; the round's own holes as a fallback
        /// for rounds whose course row is missing locally.
        func holes(for round: Round) -> [Int: Hole] {
            if let byNumber = holesByCourse[round.courseId], !byNumber.isEmpty {
                return byNumber
            }
            var byNumber: [Int: Hole] = [:]
            for hole in round.holes { byNumber[hole.number] = hole }
            return byNumber
        }

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

        // Accumulators — scoring/short-game are per round length
        var scoresByLength: [Int: [Int]] = [:]        // holeCount → [score vs par]
        var puttsByLength: [Int: [Int]] = [:]         // holeCount → [putts that round]
        var puttCountsPerHole: [Double] = []
        var girResults: [Bool] = []
        var clubTypeSamples: [UUID: [Double]] = [:]   // typeId → [yards]
        var clubSamples: [UUID: [Double]] = [:]       // clubId → [yards]
        var scoredCountByCourse: [UUID: Int] = [:]
        var scoresByCourse: [UUID: [Int]] = [:]

        for round in rounds {
            let counted = countedHoles(in: round, holesByNumber: holes(for: round))
            let qualifies = scoredHoleCounts.contains(counted.count)

            // MARK: Club distances — every round contributes, partials included.
            // GPS delta between consecutive non-penalty strokes: stroke[i] →
            // stroke[i+1] is the distance travelled, i.e. shot i's landing
            // distance.
            for hole in counted {
                for i in 0..<max(0, hole.nonPenalty.count - 1) {
                    let from = hole.nonPenalty[i]
                    let to   = hole.nonPenalty[i + 1]
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

            // Everything below is scoring — qualifying rounds only.
            guard qualifies else { continue }

            let roundPar = counted.reduce(0) { $0 + $1.par }
            let roundStrokes = counted.reduce(0) { $0 + $1.nonPenalty.count }
            var roundPutts = 0

            for hole in counted {
                let putts = hole.strokes.filter { isPutt($0) }
                roundPutts += putts.count
                puttCountsPerHole.append(Double(putts.count))

                // GIR: first putt stroke number <= par - 1
                if let firstPutt = putts.first {
                    girResults.append(firstPutt.strokeNumber <= hole.par - 1)
                }
            }

            scoresByLength[counted.count, default: []].append(roundStrokes - roundPar)
            puttsByLength[counted.count, default: []].append(roundPutts)
            scoresByCourse[round.courseId, default: []].append(roundStrokes - roundPar)
            scoredCountByCourse[round.courseId, default: 0] += 1
        }

        // MARK: Aggregate — scoring, per round length
        stats.scoring18 = scoringStats(scores: scoresByLength[18] ?? [], putts: puttsByLength[18] ?? [])
        stats.scoring9  = scoringStats(scores: scoresByLength[9]  ?? [], putts: puttsByLength[9]  ?? [])

        if !puttCountsPerHole.isEmpty {
            stats.avgPuttsPerHole = puttCountsPerHole.reduce(0, +) / Double(puttCountsPerHole.count)
        }
        if !girResults.isEmpty {
            stats.girPercent = Double(girResults.filter { $0 }.count) / Double(girResults.count) * 100
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
        // `roundsPlayed` counts every visit; scoring comes from the qualifying
        // subset only, so a course with nothing but partials shows its visit
        // count and no score.
        let roundsByCourse = Dictionary(grouping: rounds, by: { $0.courseId })
        for (courseId, courseRounds) in roundsByCourse {
            var cs = CourseStats(
                courseId: courseId,
                courseName: courseRounds.first?.courseName ?? "Unknown",
                roundsPlayed: courseRounds.count,
                scoredRounds: scoredCountByCourse[courseId] ?? 0,
                lastPlayed: courseRounds.map { $0.date }.max() ?? Date()
            )
            if let courseScores = scoresByCourse[courseId], !courseScores.isEmpty {
                cs.avgScoreVsPar = Double(courseScores.reduce(0, +)) / Double(courseScores.count)
                cs.bestScoreVsPar = courseScores.min()
                cs.worstScoreVsPar = courseScores.max()
            }
            stats.perCourseStats[courseId.uuidString] = cs
        }

        return stats
    }

    // MARK: - Aggregation helpers

    private static func scoringStats(scores: [Int], putts: [Int]) -> ScoringStats {
        guard !scores.isEmpty else { return ScoringStats() }
        var s = ScoringStats()
        s.roundCount = scores.count
        s.avgScoreVsPar = Double(scores.reduce(0, +)) / Double(scores.count)
        s.bestScoreVsPar = scores.min()
        if !putts.isEmpty {
            s.avgPuttsPerRound = Double(putts.reduce(0, +)) / Double(putts.count)
        }
        return s
    }

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
}
