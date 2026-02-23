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

struct CourseStats: Codable {
    var courseId: UUID
    var courseName: String
    var roundsPlayed: Int
    var avgScoreVsPar: Double?
    var bestScoreVsPar: Int?
    var worstScoreVsPar: Int?
    var lastPlayed: Date
}

struct PlayerStats: Codable {
    var lastUpdated: Date = Date()
    var totalRounds: Int = 0
    var totalRoundsWithPar: Int = 0

    // Scoring
    var avgScoreVsPar: Double? = nil
    var bestScoreVsPar: Int? = nil

    // Short game
    var avgPuttsPerRound: Double? = nil
    var avgPuttsPerHole: Double? = nil
    var girPercent: Double? = nil           // Greens in regulation %
    var fairwayHitPercent: Double? = nil    // Par 4/5 tee shots within threshold
    var avgDeviationDegrees: Double? = nil  // Mean absolute deviation from ideal line

    // Per club type — keyed by ClubTypeData.id.uuidString
    var perClubTypeStats: [String: ClubDistanceStats] = [:]

    // Per individual club — keyed by ClubData.id.uuidString
    var perClubStats: [String: ClubDistanceStats] = [:]

    // Per course — keyed by Course.id.uuidString
    var perCourseStats: [String: CourseStats] = [:]

    static let empty = PlayerStats()
}
