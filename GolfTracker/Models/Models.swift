import Foundation
import CoreLocation
import SwiftData

// MARK: - Club Models

@Model
final class ClubTypeData {
    @Attribute(.unique) var id: UUID
    var name: String
    var isDefault: Bool
    var averageDistance: Int?

    init(id: UUID = UUID(), name: String, isDefault: Bool, averageDistance: Int? = nil) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.averageDistance = averageDistance
    }

    static func defaultClubTypes() -> [ClubTypeData] {
        return [
            ClubTypeData(name: "Drive", isDefault: true, averageDistance: 245),
            ClubTypeData(name: "3-Wood", isDefault: true, averageDistance: 225),
            ClubTypeData(name: "5-Wood", isDefault: true, averageDistance: 207),
            ClubTypeData(name: "4-Hyb", isDefault: true, averageDistance: 192),
            ClubTypeData(name: "5-Hyb", isDefault: true, averageDistance: 180),
            ClubTypeData(name: "4-Iron", isDefault: true, averageDistance: 170),
            ClubTypeData(name: "5-Iron", isDefault: true, averageDistance: 160),
            ClubTypeData(name: "6-Iron", isDefault: true, averageDistance: 150),
            ClubTypeData(name: "7-Iron", isDefault: true, averageDistance: 140),
            ClubTypeData(name: "8-Iron", isDefault: true, averageDistance: 130),
            ClubTypeData(name: "9-Iron", isDefault: true, averageDistance: 118),
            ClubTypeData(name: "Pitch", isDefault: true, averageDistance: 106),
            ClubTypeData(name: "Gap", isDefault: true, averageDistance: 93),
            ClubTypeData(name: "Sand", isDefault: true, averageDistance: 78),
            ClubTypeData(name: "Lob", isDefault: true, averageDistance: 45),
            ClubTypeData(name: "Putt", isDefault: true, averageDistance: 10)
        ]
    }
}

@Model
final class ClubData {
    @Attribute(.unique) var id: UUID
    var name: String
    var clubTypeId: UUID    // FK to ClubTypeData
    var isDefault: Bool

    init(id: UUID = UUID(), name: String, clubTypeId: UUID, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.clubTypeId = clubTypeId
        self.isDefault = isDefault
    }
}

/// Embedded value type — owned by ClubSet, not its own table.
struct TypeSelection: Codable, Hashable {
    var typeId: UUID
    var activeClubId: UUID?
}

@Model
final class ClubSet {
    @Attribute(.unique) var id: UUID
    var name: String
    /// Stored as Codable JSON — TypeSelection is an embedded value type,
    /// not a relational entity on its own.
    var typeSelections: [TypeSelection]
    var isActive: Bool
    var dateCreated: Date
    var dateModified: Date

    init(id: UUID = UUID(),
         name: String,
         typeSelections: [TypeSelection] = [],
         isActive: Bool = false,
         dateCreated: Date = Date(),
         dateModified: Date = Date()) {
        self.id = id
        self.name = name
        self.typeSelections = typeSelections
        self.isActive = isActive
        self.dateCreated = dateCreated
        self.dateModified = dateModified
    }

    func getActiveClubId(for typeId: UUID) -> UUID? {
        typeSelections.first(where: { $0.typeId == typeId })?.activeClubId
    }

    func hasType(_ typeId: UUID) -> Bool {
        typeSelections.contains(where: { $0.typeId == typeId })
    }
}

// MARK: - Course / Hole / Round / Stroke / Target

@Model
final class Course {
    @Attribute(.unique) var id: UUID
    var name: String
    /// Course's authoritative hole list. Round snapshots this at start so that
    /// edits to the course don't retroactively rewrite history.
    @Relationship(deleteRule: .cascade, inverse: \Hole.course) var holes: [Hole]
    var rating: Double?
    var slope: Int?
    var city: String?

    init(id: UUID = UUID(),
         name: String,
         holes: [Hole] = [],
         rating: Double? = nil,
         slope: Int? = nil,
         city: String? = nil) {
        self.id = id
        self.name = name
        self.holes = holes
        self.rating = rating
        self.slope = slope
        self.city = city
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let firstHole = holes.first else { return nil }
        return firstHole.coordinate
    }
}

@Model
final class Hole {
    @Attribute(.unique) var id: UUID
    var number: Int
    var latitude: Double?
    var longitude: Double?
    var par: Int?
    /// Inverse relationship: nil if this hole is owned by a Round (round-time
    /// snapshot) rather than a course directly.
    var course: Course?
    var round: Round?

    init(id: UUID = UUID(),
         number: Int,
         coordinate: CLLocationCoordinate2D? = nil,
         par: Int? = nil) {
        self.id = id
        self.number = number
        self.latitude = coordinate?.latitude
        self.longitude = coordinate?.longitude
        self.par = par
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let lat = latitude, let lon = longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var hasLocation: Bool { latitude != nil && longitude != nil }

    func setCoordinate(_ coordinate: CLLocationCoordinate2D) {
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }
}

@Model
final class Stroke {
    @Attribute(.unique) var id: UUID
    var holeNumber: Int
    var strokeNumber: Int
    var latitude: Double
    var longitude: Double
    var clubId: UUID    // FK to ClubData
    var timestamp: Date
    var isPenalty: Bool
    var trajectoryHeading: Double?
    var round: Round?

    init(id: UUID = UUID(),
         holeNumber: Int,
         strokeNumber: Int,
         coordinate: CLLocationCoordinate2D,
         clubId: UUID,
         isPenalty: Bool = false,
         trajectoryHeading: Double? = nil,
         timestamp: Date = Date()) {
        self.id = id
        self.holeNumber = holeNumber
        self.strokeNumber = strokeNumber
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.clubId = clubId
        self.timestamp = timestamp
        self.isPenalty = isPenalty
        self.trajectoryHeading = trajectoryHeading
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension Stroke {
    /// Compute the next stroke number for a given hole within a round.
    static func nextStrokeNumber(in round: Round, holeNumber: Int) -> Int {
        round.strokes.filter { $0.holeNumber == holeNumber }.count + 1
    }
}

@Model
final class Target {
    @Attribute(.unique) var id: UUID
    var holeNumber: Int
    var latitude: Double
    var longitude: Double
    var round: Round?

    init(id: UUID = UUID(),
         holeNumber: Int,
         coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.holeNumber = holeNumber
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

@Model
final class Round {
    @Attribute(.unique) var id: UUID
    var courseId: UUID
    var courseName: String
    var date: Date
    @Relationship(deleteRule: .cascade, inverse: \Stroke.round) var strokes: [Stroke]
    /// Round-time snapshot of course holes — separate ownership from Course.holes
    /// so edits to the parent course don't rewrite history.
    @Relationship(deleteRule: .cascade, inverse: \Hole.round) var holes: [Hole]
    /// Stored as [Int] (SwiftData support for Set<Int> is flaky); exposed as
    /// Set<Int> via `completedHoles` computed property below.
    var completedHolesArray: [Int]
    var currentHoleIndex: Int
    @Relationship(deleteRule: .cascade, inverse: \Target.round) var targets: [Target]
    var holeDetectionEnabled: Bool?
    var locationTestModeEnabled: Bool?

    init(id: UUID = UUID(),
         courseId: UUID,
         courseName: String,
         holes: [Hole] = [],
         holeDetectionEnabled: Bool = false,
         locationTestModeEnabled: Bool = false,
         date: Date = Date()) {
        self.id = id
        self.courseId = courseId
        self.courseName = courseName
        self.date = date
        self.strokes = []
        self.holes = holes
        self.completedHolesArray = []
        self.currentHoleIndex = 0
        self.targets = []
        self.holeDetectionEnabled = holeDetectionEnabled
        self.locationTestModeEnabled = locationTestModeEnabled
    }

    var completedHoles: Set<Int> {
        get { Set(completedHolesArray) }
        set { completedHolesArray = Array(newValue) }
    }

    func isHoleCompleted(_ holeNumber: Int) -> Bool {
        completedHolesArray.contains(holeNumber)
    }
}

// MARK: - Hole Detection Models (transient, JSON-only — not @Model)

struct MapPoint: Codable, Hashable {
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }
}

struct HoleDetectionBlob: Identifiable, Codable, Hashable {
    var id = UUID()
    var area: Int
    var minWidth: Double
    var elongation: Double
    var greennessScore: Int
    var centroidLatitude: Double
    var centroidLongitude: Double
    var polygon: [MapPoint]

    var centroidCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: centroidLatitude, longitude: centroidLongitude)
    }

    var polygonCoordinates: [CLLocationCoordinate2D] {
        polygon.map { $0.coordinate }
    }

    func centroidDistanceMeters(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: centroidLatitude, longitude: centroidLongitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }

    func passesFilter(_ settings: HoleDetectionFilterSettings) -> Bool {
        area >= settings.minArea &&
        minWidth >= settings.minWidth &&
        elongation <= settings.maxElongation &&
        greennessScore >= settings.minGreennessScore
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard polygon.count >= 3 else { return false }

        let x = coordinate.longitude
        let y = coordinate.latitude
        var isInside = false
        var j = polygon.count - 1

        for i in 0..<polygon.count {
            let xi = polygon[i].longitude
            let yi = polygon[i].latitude
            let xj = polygon[j].longitude
            let yj = polygon[j].latitude

            let intersects = ((yi > y) != (yj > y)) &&
                (x < ((xj - xi) * (y - yi) / max((yj - yi), 1.0e-12)) + xi)
            if intersects {
                isInside.toggle()
            }
            j = i
        }

        return isInside
    }
}

struct CourseHoleDetectionData: Codable, Hashable {
    var courseId: UUID
    var generatedAt: Date
    var blobs: [HoleDetectionBlob]
}

struct HoleDetectionFilterSettings: Codable, Hashable {
    var minArea: Int
    var minWidth: Double
    var maxElongation: Double
    var minGreennessScore: Int

    static let `default` = HoleDetectionFilterSettings(
        minArea: 0,
        minWidth: 0,
        maxElongation: 100.0,
        minGreennessScore: 0
    )
}

// MARK: - Auth (transient, Keychain-only — not @Model)

struct AuthSession: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let userId: String
}
