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
    /// Course's authoritative hole list. Rounds share these Hole instances
    /// (see Round.holes) — hole edits are corrections and apply everywhere,
    /// past rounds included.
    @Relationship(deleteRule: .cascade, inverse: \Hole.course) var holes: [Hole]
    var rating: Double?
    var slope: Int?
    var city: String?
    /// Course centroid in lat/lon. Used by the resolver's proximity query —
    /// the very first lookup when a user starts a round. Populated when the
    /// course is first registered via OSM resolution.
    var centerLat: Double?
    var centerLon: Double?
    /// OSM way/relation id for this course (when sourced from OSM).
    /// Uniqueness-constrained server-side so two clients resolving the same
    /// OSM course collapse to the same row.
    var osmId: Int64?
    /// GolfCourseAPI's course id (when matched). Same uniqueness rule.
    /// Tee picker reads `course_tees` keyed by this; round-time scorecard
    /// data flows through `course_tee_holes`.
    var externalCourseId: String?
    /// Polygon detail from OSM (greens, tees, fairways, bunkers, course
    /// outline) as raw JSON. Per-hole data lives in `holes` (per-row) for
    /// indexable access; this column carries the supporting geometry that
    /// doesn't fit naturally as table rows.
    var osmPolygons: Data?

    init(id: UUID = UUID(),
         name: String,
         holes: [Hole] = [],
         rating: Double? = nil,
         slope: Int? = nil,
         city: String? = nil,
         centerLat: Double? = nil,
         centerLon: Double? = nil,
         osmId: Int64? = nil,
         externalCourseId: String? = nil,
         osmPolygons: Data? = nil) {
        self.id = id
        self.name = name
        self.holes = holes
        self.rating = rating
        self.slope = slope
        self.city = city
        self.centerLat = centerLat
        self.centerLon = centerLon
        self.osmId = osmId
        self.externalCourseId = externalCourseId
        self.osmPolygons = osmPolygons
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
    /// Per-hole snapshot of which tee was active when this hole was played.
    /// Set at round start from `Round.selectedTeeId`; preserved through any
    /// mid-round tee changes so future holes can update without rewriting
    /// history. References `course_tees.id` (no SwiftData @Relationship since
    /// CourseTees aren't @Model — they live in Supabase only as cached rows).
    var teeId: UUID?
    /// Inverse relationship: nil if this hole is owned by a Round (round-time
    /// snapshot) rather than a course directly.
    var course: Course?
    var round: Round?
    /// Stored parent round id used to re-adopt orphan holes if the parent
    /// Round insert arrives after this row (Realtime can deliver child rows
    /// before parents). When `round` is nil but `roundIdRef` matches a Round
    /// that later lands, `applyRound` re-attaches via this id.
    var roundIdRef: UUID?

    init(id: UUID = UUID(),
         number: Int,
         coordinate: CLLocationCoordinate2D? = nil,
         par: Int? = nil,
         teeId: UUID? = nil) {
        self.id = id
        self.number = number
        self.latitude = coordinate?.latitude
        self.longitude = coordinate?.longitude
        self.par = par
        self.teeId = teeId
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
    /// Barometric relative altitude at the moment the stroke was recorded,
    /// in meters. Values within one round are referenced to the same
    /// anchor (altimeter zero-point at round start), so deltas between
    /// strokes on the same hole are drift-free. Comparable across strokes
    /// in the same round; not comparable across rounds or users without
    /// the cross-user calibration step.
    var relAltMeters: Double?
    var round: Round?
    /// Stored parent round id — see `Hole.roundIdRef` for the rationale.
    /// Set by `RealtimeSync.applyStroke` so orphan strokes can be re-adopted
    /// when the parent Round insert lands after them.
    var roundIdRef: UUID?

    init(id: UUID = UUID(),
         holeNumber: Int,
         strokeNumber: Int,
         coordinate: CLLocationCoordinate2D,
         clubId: UUID,
         isPenalty: Bool = false,
         trajectoryHeading: Double? = nil,
         relAltMeters: Double? = nil,
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
        self.relAltMeters = relAltMeters
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
    /// The round's holes — intentionally the SAME Hole instances the parent
    /// course owns (rounds inherit pars/locations from the course; course
    /// edits are corrections, greens don't physically move). Delete rule is
    /// nullify, NOT cascade: deleting a round must never delete the course's
    /// holes out from under it.
    @Relationship(deleteRule: .nullify, inverse: \Hole.round) var holes: [Hole]
    /// Stored as [Int] (SwiftData support for Set<Int> is flaky); exposed as
    /// Set<Int> via `completedHoles` computed property below.
    var completedHolesArray: [Int]
    var currentHoleIndex: Int
    @Relationship(deleteRule: .cascade, inverse: \Target.round) var targets: [Target]
    var holeDetectionEnabled: Bool?
    var locationTestModeEnabled: Bool?
    /// User's currently-selected tee. References `course_tees.id` in Supabase.
    /// Set when the user picks at round start; updated when they change tee
    /// mid-round (via Settings). Nil for rounds at courses GolfCourseAPI
    /// doesn't have (no tee picker shown).
    var selectedTeeId: UUID?
    /// Round-completion marker. Nil while in progress; set to the end
    /// timestamp by the manual End Round button, the inactivity sweep
    /// (lastActivityAt > 1h ago), the off-course sweep (>2km from every
    /// hole), and the auto-end-prior path when a new round starts.
    /// `currentRound` getters filter `endedAt == nil`.
    var endedAt: Date?
    /// Last user-driven activity on this round — bumped on stroke add and
    /// hole-index change. Drives the inactivity sweep. Single shared
    /// column across devices: either device updating it is enough since
    /// Realtime sync echoes the value to the other device.
    var lastActivityAt: Date?

    init(id: UUID = UUID(),
         courseId: UUID,
         courseName: String,
         holes: [Hole] = [],
         holeDetectionEnabled: Bool = false,
         locationTestModeEnabled: Bool = false,
         date: Date = Date(),
         selectedTeeId: UUID? = nil) {
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
        self.selectedTeeId = selectedTeeId
        self.endedAt = nil
        self.lastActivityAt = date
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

    func passesShapeFilter(_ settings: HoleDetectionFilterSettings) -> Bool {
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

            // Standard ray-casting. The straddle precondition `(yi > y) != (yj > y)`
            // guarantees `yj - yi` is non-zero with meaningful magnitude, so no
            // division-by-zero guard is needed. (Previously this used
            // `max((yj - yi), 1.0e-12)` which clamped negative deltas to a tiny
            // positive number, corrupting the math for any edge going downward
            // in latitude — about half the edges in any clockwise-traced polygon.)
            let intersects = ((yi > y) != (yj > y)) &&
                (x < (xj - xi) * (y - yi) / (yj - yi) + xi)
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
    /// Master toggle. When false the filter is bypassed entirely and the
    /// raw analyzer output passes through unchanged.
    var enabled: Bool
    var minArea: Int
    var minWidth: Double
    var maxElongation: Double
    var minGreennessScore: Int
    /// Keep only the top-N blobs ranked by greennessScore desc. Lets users
    /// cut a 60-blob analyzer run down to ~18-25 candidates.
    var maxRank: Int

    static let `default` = HoleDetectionFilterSettings(
        enabled: true,
        minArea: 0,
        minWidth: 0,
        maxElongation: 100.0,
        minGreennessScore: 0,
        maxRank: 100
    )

    /// Filter pipeline: when `enabled` is false, returns blobs unchanged.
    /// Otherwise applies per-blob shape gates (area/width/elong/score),
    /// then keeps only the top-`maxRank` survivors ranked by greennessScore
    /// descending. Rank ties resolved by blob id for determinism.
    func apply(to blobs: [HoleDetectionBlob]) -> [HoleDetectionBlob] {
        guard enabled else { return blobs }
        let shapePassed = blobs.filter { $0.passesShapeFilter(self) }
        let ranked = shapePassed.sorted {
            if $0.greennessScore != $1.greennessScore { return $0.greennessScore > $1.greennessScore }
            return $0.id.uuidString < $1.id.uuidString
        }
        return Array(ranked.prefix(maxRank))
    }
}

// MARK: - Auth (transient, Keychain-only — not @Model)

struct AuthSession: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let userId: String
}

// MARK: - Multiplayer wire types (read from Supabase, not @Model)

/// User profile — first name + display name for the multiplayer picker.
/// One row per auth.users.id, public-readable so the host's name shows in
/// every nearby joiner's "Join Round" list.
struct UserProfile: Codable, Hashable {
    let userId: String
    var firstName: String?
    var displayName: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case firstName = "first_name"
        case displayName = "display_name"
    }

    /// Display name resolution: explicit override → first name → "Player".
    var resolvedName: String {
        if let display = displayName, !display.isEmpty { return display }
        if let first = firstName, !first.isEmpty { return first }
        return "Player"
    }
}

/// One playgroup (shared round session). Status governs whether it accepts
/// new joiners; ended_at marks round completion.
struct Playgroup: Codable, Hashable, Identifiable {
    let id: UUID
    let hostId: String
    let courseId: UUID?
    let courseName: String
    let startedAt: Date
    let closedAt: Date?
    let endedAt: Date?
    let status: String
    let name: String?
    /// Captured from the host's GPS at hostPlaygroup() time. Used to filter
    /// the joiner's "Nearby" list — joiners only see groups within range.
    let hostLat: Double?
    let hostLon: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case hostId = "host_id"
        case courseId = "course_id"
        case courseName = "course_name"
        case startedAt = "started_at"
        case closedAt = "closed_at"
        case endedAt = "ended_at"
        case status, name
        case hostLat = "host_lat"
        case hostLon = "host_lon"
    }

    var isOpen: Bool { status == "open" }
}

struct PlaygroupMember: Codable, Hashable {
    let playgroupId: UUID
    let userId: String
    let roundId: UUID?
    let color: String?
    let joinedAt: Date
    let leftAt: Date?

    enum CodingKeys: String, CodingKey {
        case playgroupId = "playgroup_id"
        case userId = "user_id"
        case roundId = "round_id"
        case color
        case joinedAt = "joined_at"
        case leftAt = "left_at"
    }
}

struct PlaygroupJoinRequest: Codable, Hashable, Identifiable {
    let id: UUID
    let playgroupId: UUID
    let requesterId: String
    let requestedAt: Date
    let status: String
    let respondedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case playgroupId = "playgroup_id"
        case requesterId = "requester_id"
        case requestedAt = "requested_at"
        case status
        case respondedAt = "responded_at"
    }

    var isPending: Bool { status == "pending" }
}

// MARK: - Club catalog hydrate DTOs (shared iOS + watch)

/// Wire shapes for the one-shot Supabase fetch in `WatchDataStore.hydrateClubsFromSupabase`
/// and `DataStore.reconcileClubsWithSupabase`. Snake-case property names match Postgres
/// column names directly so we don't need a CodingKeys block.
struct ClubTypeDTO: Decodable {
    let id: UUID
    let name: String
    let is_default: Bool?
    let average_distance: Int?
}

struct ClubDTO: Decodable {
    let id: UUID
    let name: String
    let club_type_id: UUID
    let is_default: Bool?
}

struct ClubSetDTO: Decodable {
    let id: UUID
    let name: String
    let is_active: Bool?
    let date_created: String?
    let date_modified: String?
}

/// One row of the `club_set_type_selections` join table — links a ClubSet
/// to which Club is currently active for each ClubType. Hydrated alongside
/// `club_sets` so local ClubSet.typeSelections gets populated.
struct ClubSetTypeSelectionDTO: Decodable {
    let club_set_id: UUID
    let type_id: UUID
    let active_club_id: UUID?
}
