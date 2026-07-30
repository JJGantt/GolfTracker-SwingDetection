import Foundation

struct ClubDistanceStats: Codable {
    var id: UUID
    var name: String
    var sampleCount: Int
    var avgDistanceYards: Double
    var trimmedAvgDistanceYards: Double  // 10% trimmed mean — used by smart predictor
    var medianDistanceYards: Double
    var stdDevYards: Double
    var minYards: Double
    var maxYards: Double

    /// Enough samples to trust this data for prediction (min 5)
    var isReliable: Bool { sampleCount >= 5 }
}

/// Scoring aggregates for one round length. Kept separate per length because
/// a 9-hole score and an 18-hole score are not comparable — averaging them
/// together is the same category error as averaging a 5K time with a
/// marathon time.
struct ScoringStats: Codable {
    var roundCount: Int = 0
    var avgScoreVsPar: Double? = nil
    var bestScoreVsPar: Int? = nil
    var avgPuttsPerRound: Double? = nil

    var isEmpty: Bool { roundCount == 0 }
}

struct CourseStats: Codable {
    var courseId: UUID
    var courseName: String
    /// Every round started at this course, partials included.
    var roundsPlayed: Int
    /// Subset of `roundsPlayed` that qualified for scoring (a real 9 or 18).
    var scoredRounds: Int = 0
    var avgScoreVsPar: Double?
    var bestScoreVsPar: Int?
    var worstScoreVsPar: Int?
    var lastPlayed: Date
}

struct PlayerStats: Codable {
    var lastUpdated: Date = Date()
    /// Every round on record, partials and abandoned attempts included.
    var totalRounds: Int = 0

    // Scoring — split by round length. Partial rounds feed neither.
    var scoring18: ScoringStats = ScoringStats()
    var scoring9: ScoringStats = ScoringStats()

    /// Rounds that qualified for scoring, across both lengths.
    var scoredRounds: Int { scoring18.roundCount + scoring9.roundCount }

    // Short game — computed over qualifying rounds only, same as scoring.
    var avgPuttsPerHole: Double? = nil
    var girPercent: Double? = nil           // Greens in regulation %
    var avgDeviationDegrees: Double? = nil  // Mean absolute deviation from ideal line

    // Per club type — keyed by ClubTypeData.id.uuidString.
    // Distances come from EVERY round, partials included: a shot is a shot,
    // and more samples make the distribution better.
    var perClubTypeStats: [String: ClubDistanceStats] = [:]

    // Per individual club — keyed by ClubData.id.uuidString
    var perClubStats: [String: ClubDistanceStats] = [:]

    // Per course — keyed by Course.id.uuidString
    var perCourseStats: [String: CourseStats] = [:]

    static let empty = PlayerStats()

    private enum CodingKeys: String, CodingKey {
        case lastUpdated, totalRounds, scoring18, scoring9
        case avgPuttsPerHole, girPercent, avgDeviationDegrees
        case perClubTypeStats, perClubStats, perCourseStats
    }
}
