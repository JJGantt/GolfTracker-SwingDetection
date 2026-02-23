import Foundation
import CoreLocation

// MARK: - Club Models

struct ClubTypeData: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String              // Display name (e.g., "Driver", "7-Iron", "Sand Wedge")
    var isDefault: Bool           // Default types can't be deleted
    var averageDistance: Int?     // Average distance in yards (for club prediction)

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

struct ClubData: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String              // Display name (e.g., "3-Iron", "My TaylorMade 7-Iron")
    var clubTypeId: UUID          // For stats grouping - references ClubTypeData
    var isDefault: Bool           // Default clubs can't be deleted

}

struct TypeSelection: Codable, Hashable {
    var typeId: UUID
    var activeClubId: UUID?       // Which club of this type is active (nil if none selected)
}

struct ClubSet: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String              // e.g., "My Main Bag"
    var typeSelections: [TypeSelection]  // Types in this set with their active club
    var isActive: Bool            // Currently selected set
    var dateCreated: Date
    var dateModified: Date

    init(name: String, typeSelections: [TypeSelection] = [], isActive: Bool = false) {
        self.name = name
        self.typeSelections = typeSelections
        self.isActive = isActive
        self.dateCreated = Date()
        self.dateModified = Date()
    }

    func getActiveClubId(for typeId: UUID) -> UUID? {
        typeSelections.first(where: { $0.typeId == typeId })?.activeClubId
    }

    func hasType(_ typeId: UUID) -> Bool {
        typeSelections.contains(where: { $0.typeId == typeId })
    }
}


struct Course: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var holes: [Hole]
    var rating: Double?
    var slope: Int?
    var city: String?

    var coordinate: CLLocationCoordinate2D? {
        guard let firstHole = holes.first else { return nil }
        return firstHole.coordinate
    }
}

struct Hole: Identifiable, Codable, Hashable {
    var id = UUID()
    var number: Int
    var latitude: Double?
    var longitude: Double?
    var par: Int?

    var coordinate: CLLocationCoordinate2D? {
        guard let lat = latitude, let lon = longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Whether this hole has a flag location set
    var hasLocation: Bool {
        latitude != nil && longitude != nil
    }

    init(number: Int, coordinate: CLLocationCoordinate2D? = nil, par: Int? = nil) {
        self.number = number
        self.latitude = coordinate?.latitude
        self.longitude = coordinate?.longitude
        self.par = par
    }

    /// Update the hole's flag location
    mutating func setCoordinate(_ coordinate: CLLocationCoordinate2D) {
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }
}

struct Stroke: Identifiable, Codable, Hashable {
    var id = UUID()
    var holeNumber: Int
    var strokeNumber: Int
    var latitude: Double
    var longitude: Double
    var clubId: UUID              // References ClubData.id
    var timestamp: Date
    var landingLatitude: Double?
    var landingLongitude: Double?
    var isPenalty: Bool
    var trajectoryHeading: Double? // Direction user was trying to hit (in degrees)
    var acceleration: Double? // Peak acceleration in G when swing was detected

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var landingCoordinate: CLLocationCoordinate2D? {
        guard let lat = landingLatitude, let lon = landingLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    init(holeNumber: Int, strokeNumber: Int, coordinate: CLLocationCoordinate2D, clubId: UUID, isPenalty: Bool = false, trajectoryHeading: Double? = nil, acceleration: Double? = nil) {
        self.holeNumber = holeNumber
        self.strokeNumber = strokeNumber
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.clubId = clubId
        self.timestamp = Date()
        self.isPenalty = isPenalty
        self.trajectoryHeading = trajectoryHeading
        self.acceleration = acceleration
    }
}

struct Target: Identifiable, Codable, Hashable {
    var id = UUID()
    var holeNumber: Int
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(holeNumber: Int, coordinate: CLLocationCoordinate2D) {
        self.holeNumber = holeNumber
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }
}

struct Round: Identifiable, Codable, Hashable {
    var id = UUID()
    var courseId: UUID
    var courseName: String
    var date: Date
    var strokes: [Stroke]
    var holes: [Hole] // Course holes for Watch sync
    var completedHoles: Set<Int> // Hole numbers that have been finished
    var currentHoleIndex: Int // Current hole being played (synced between devices)
    var targets: [Target] // Target markers placed on the map (synced between devices)
    var holeDetectionEnabled: Bool? // Whether green suggestions are enabled for this round
    var locationTestModeEnabled: Bool? // Whether GPS should be forced to fixed test coordinates

    init(
        courseId: UUID,
        courseName: String,
        holes: [Hole] = [],
        holeDetectionEnabled: Bool = false,
        locationTestModeEnabled: Bool = false
    ) {
        self.courseId = courseId
        self.courseName = courseName
        self.date = Date()
        self.strokes = []
        self.holes = holes
        self.completedHoles = []
        self.currentHoleIndex = 0
        self.targets = []
        self.holeDetectionEnabled = holeDetectionEnabled
        self.locationTestModeEnabled = locationTestModeEnabled
    }

    func isHoleCompleted(_ holeNumber: Int) -> Bool {
        return completedHoles.contains(holeNumber)
    }
}

// MARK: - Hole Detection Models

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

// MARK: - Satellite Imagery Models

struct SatelliteImageMetadata: Identifiable, Codable, Hashable {
    var id = UUID()
    var courseId: UUID
    var holeNumber: Int
    var centerLatitude: Double
    var centerLongitude: Double
    var radiusMeters: Double // 550 meters (600 yards)
    var pixelWidth: Int // 2000
    var pixelHeight: Int // 2000
    var metersPerPixel: Double
    var capturedDate: Date
    var fileName: String

    var centerCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude)
    }

    init(courseId: UUID, holeNumber: Int, center: CLLocationCoordinate2D, radiusMeters: Double = 550.0, pixelWidth: Int = 2000, pixelHeight: Int = 2000) {
        self.courseId = courseId
        self.holeNumber = holeNumber
        self.centerLatitude = center.latitude
        self.centerLongitude = center.longitude
        self.radiusMeters = radiusMeters
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.metersPerPixel = (radiusMeters * 2) / Double(pixelWidth)
        self.capturedDate = Date()
        self.fileName = "\(courseId.uuidString)_hole-\(holeNumber).jpg"
    }
}

struct LargeSatelliteImageMetadata: Codable {
    var fileName: String // "large_satellite.jpg"
    var centerLatitude: Double
    var centerLongitude: Double
    var radiusMeters: Double // 1000 meters (2km diameter)
    var pixelWidth: Int // 2000
    var pixelHeight: Int // 2000
    var metersPerPixel: Double
    var capturedDate: Date

    var centerCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude)
    }

    init(center: CLLocationCoordinate2D, radiusMeters: Double = 1000.0, pixelWidth: Int = 2000, pixelHeight: Int = 2000) {
        self.fileName = "large_satellite.jpg"
        self.centerLatitude = center.latitude
        self.centerLongitude = center.longitude
        self.radiusMeters = radiusMeters
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.metersPerPixel = (radiusMeters * 2) / Double(pixelWidth)
        self.capturedDate = Date()
    }
}

struct CourseSatelliteCache: Codable {
    var courseId: UUID
    var courseName: String
    var largeImage: LargeSatelliteImageMetadata? // The big 3km×3km image
    var images: [SatelliteImageMetadata] // Per-hole crops
    var lastUpdated: Date
    var version: Int = 1

    init(courseId: UUID, courseName: String, largeImage: LargeSatelliteImageMetadata? = nil, images: [SatelliteImageMetadata] = []) {
        self.courseId = courseId
        self.courseName = courseName
        self.largeImage = largeImage
        self.images = images
        self.lastUpdated = Date()
    }
}
