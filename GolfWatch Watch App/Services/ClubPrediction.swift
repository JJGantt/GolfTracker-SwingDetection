import Foundation

// MARK: - Club Prediction Mode

enum ClubPredictionMode: String, Codable, CaseIterable {
    case off = "Off"
    case naive = "Naive"
    case smart = "Smart"
    case manual = "Manual"
}

// MARK: - Club Prediction Manager

final class ClubPredictionManager: Sendable {
    static let shared = ClubPredictionManager()

    /// Club types skipped by distance-based prediction unconditionally.
    /// - "Sand": special-purpose, only chosen by manual override.
    /// "Putt" is NOT here — it's excluded conditionally by the caller (only
    /// when an OSM green polygon is available for the current hole, since
    /// polygon containment is the authoritative signal in that case). When
    /// no polygon exists, distance-based prediction can still pick putter
    /// as the fallback.
    static let excludedFromPrediction: Set<String> = ["Sand"]

    private let naiveDistances: [String: Int] = [
        "Drive": 245, "3-Wood": 225, "5-Wood": 207,
        "4-Hyb": 192, "5-Hyb": 180,
        "4-Iron": 170, "5-Iron": 160, "6-Iron": 150, "7-Iron": 140, "8-Iron": 130, "9-Iron": 118,
        "Pitch": 106, "Gap": 93, "Lob": 45, "Putt": 10
    ]

    private init() {}

    func getAverage(for clubType: ClubTypeData, mode: ClubPredictionMode, customAverages: [String: Int]) -> Int {
        switch mode {
        case .naive, .smart:
            return clubType.averageDistance ?? naiveDistances[clubType.name] ?? 100
        case .manual:
            return customAverages[clubType.name] ?? clubType.averageDistance ?? naiveDistances[clubType.name] ?? 100
        case .off:
            return clubType.averageDistance ?? naiveDistances[clubType.name] ?? 100
        }
    }

    /// `deltaMeters` — elevation delta to the target from ElevationReadout.
    /// When present, each candidate is scored against the plays-like
    /// distance computed with that club's own landing angle (self-
    /// consistent, no dependence on the currently selected club) instead
    /// of the raw yardage. Nil (no elevation solution) falls back to the
    /// raw-distance match.
    func predictClubIndex(forDistance yards: Int, deltaMeters: Double? = nil, clubs: [ClubData], clubTypes: [ClubTypeData], mode: ClubPredictionMode, customAverages: [String: Int] = [:], disabledClubs: Set<String> = []) -> Int? {
        guard mode != .off, !clubs.isEmpty else { return nil }

        var clubDistances: [(index: Int, average: Int, name: String)] = []
        for (index, club) in clubs.enumerated() {
            guard let clubType = clubTypes.first(where: { $0.id == club.clubTypeId }) else { continue }
            guard !Self.excludedFromPrediction.contains(clubType.name) else { continue }
            guard !disabledClubs.contains(clubType.name) else { continue }
            let average = getAverage(for: clubType, mode: mode, customAverages: customAverages)
            clubDistances.append((index, average, clubType.name))
        }
        guard !clubDistances.isEmpty else { return nil }
        let closest = PlaysLike.bestCandidate(
            distanceYards: yards,
            deltaMeters: deltaMeters,
            candidates: clubDistances.map { (item: $0, typeName: $0.name, averageYards: $0.average) }
        )
        return closest?.index
    }
}
