import Foundation
import CoreLocation
import CryptoKit
import SwiftData

// MARK: - Club Models

@Model
final class ClubTypeData {
    @Attribute(.unique) var id: UUID
    var name: String
    var isDefault: Bool
    var averageDistance: Int?
    /// User-controlled position in the bag, 0-based. Authoritative once set —
    /// the drag-to-reorder in `ClubSetEditorView` writes it and it syncs to
    /// Supabase (`club_types.sort_order`).
    ///
    /// Optional so SwiftData can migrate existing stores without a mapping
    /// model. `nil` means "never ordered on this device"; `DataStore
    /// .loadClubTypes` backfills those from the canonical order on first load,
    /// so nil is transient, not a steady state.
    var sortOrder: Int?

    init(id: UUID = UUID(), name: String, isDefault: Bool, averageDistance: Int? = nil, sortOrder: Int? = nil) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.averageDistance = averageDistance
        self.sortOrder = sortOrder
    }

    /// The built-in catalog, already in bag order. `sortOrder` is stamped from
    /// the array position so a fresh install is ordered from the first launch
    /// rather than relying on the load-time backfill.
    static func defaultClubTypes() -> [ClubTypeData] {
        let types = [
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
        types.renumberBagOrder()
        return types
    }
}

// MARK: - Canonical bag order

extension ClubTypeData {
    /// The DEFAULT club-type order, Drive → Putt. Derived from
    /// `defaultClubTypes()` so there is a single declaration and no parallel
    /// list to drift out of sync.
    ///
    /// This is only the starting point. Once `sortOrder` is assigned, the
    /// user's own arrangement wins — including for types they created, which
    /// is the whole reason the order is persisted rather than computed.
    static let canonicalOrder: [String] = defaultClubTypes().map(\.name)

    /// Parallel to `canonicalOrder` — used to slot unrecognized types into the
    /// right neighborhood rather than dumping them at the end.
    private static let canonicalDistances: [Int] = defaultClubTypes().map { $0.averageDistance ?? 0 }

    /// Fallback position for a type that has never been assigned a
    /// `sortOrder`. Deliberately NOT a plain `averageDistance` sort: a
    /// user-created type has no distance and would land at the bottom, and
    /// editing a club's distance would silently reshuffle the whole bag.
    ///
    /// A type whose name isn't canonical — user-created, or a built-in the
    /// user renamed — is slotted by its `averageDistance` against the
    /// canonical ladder, landing between its neighbors. Types with neither a
    /// known name nor a distance sort last.
    var defaultBagOrderIndex: Double {
        if let i = Self.canonicalOrder.firstIndex(of: name) { return Double(i) }
        guard let d = averageDistance else { return Double(Self.canonicalOrder.count) }
        let slot = Self.canonicalDistances.firstIndex(where: { $0 < d }) ?? Self.canonicalDistances.count
        return Double(slot) - 0.5
    }

    /// Effective sort key. The user's persisted `sortOrder` when present,
    /// otherwise the default position. Unordered types sort *after* ordered
    /// ones so a freshly-synced custom type appends rather than jumping the
    /// user's arrangement.
    var bagOrderKey: (Int, Double, String) {
        sortOrder.map { (0, Double($0), name) } ?? (1, defaultBagOrderIndex, name)
    }
}

extension Array where Element == ClubTypeData {
    /// The user's bag order, falling back to Drive → Putt for anything never
    /// arranged. Apply this wherever club types are loaded so every consumer
    /// inherits one order — SwiftData fetches have no inherent ordering and
    /// come back in insertion order, which is what left the crown and the
    /// stats list jumbled.
    func inBagOrder() -> [ClubTypeData] {
        sorted { a, b in
            let (ka, kb) = (a.bagOrderKey, b.bagOrderKey)
            if ka.0 != kb.0 { return ka.0 < kb.0 }
            if ka.1 != kb.1 { return ka.1 < kb.1 }
            return ka.2 < kb.2
        }
    }

    /// Stamp `sortOrder` to match this array's current order. Returns true if
    /// anything changed, so callers can skip a pointless save + sync.
    /// Not `mutating` — `ClubTypeData` is a reference type, so this writes
    /// through to the elements without touching the array itself.
    @discardableResult
    func renumberBagOrder() -> Bool {
        var changed = false
        for (index, type) in enumerated() where type.sortOrder != index {
            type.sortOrder = index
            changed = true
        }
        return changed
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
    /// Course holes only, mirroring `holes.owner_id`: nil for a shared hole
    /// (derived from OSM, which nobody edits), else the user who placed it.
    /// A course shows one hole per number, and the user's own beats the
    /// shared one (`RealtimeSync.applyHole`).
    var ownerId: UUID?

    var isShared: Bool { ownerId == nil }

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

    /// The id of hole `number` in round `roundId`, identical on every device:
    /// SHA-256 of the pair with the UUID version and variant bits set. Two
    /// devices that create or repair the same round hole write the same row,
    /// rather than two rows fighting over `round_holes (round_id, number)`.
    static func roundHoleId(roundId: UUID, number: Int) -> UUID {
        var b = Array(SHA256.hash(data: Data("\(roundId.uuidString.lowercased())#\(number)".utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// This hole's values as round `roundId`'s own hole.
    func roundCopy(roundId: UUID, teeId: UUID? = nil) -> Hole {
        Hole(id: Hole.roundHoleId(roundId: roundId, number: number),
             number: number, coordinate: coordinate, par: par, teeId: teeId ?? self.teeId)
    }
}

extension Array where Element == Hole {
    /// One hole per number (the first seen), in number order. A course can
    /// hold two holes for a number until `RealtimeSync.reconcileCourseHoles` runs,
    /// and two round copies of one number would share an id.
    var oneByNumber: [Hole] {
        var seen = Set<Int>()
        return sorted { $0.number < $1.number }.filter { seen.insert($0.number).inserted }
    }
}

extension ModelContext {
    /// Rounds from before round holes were copied hold their course's `Hole`
    /// instances. Give each such round its own copies (the values it was
    /// sharing) and detach the course's holes, so no course hole belongs to a
    /// round. Returns the rounds changed: their `round_holes` rows still carry
    /// the old ids and are rewritten by `SupabaseSync.rewritePendingRoundHoles`.
    func separateRoundHolesFromCourseHoles() -> [UUID] {
        let shared = (try? fetch(FetchDescriptor<Hole>(predicate: #Predicate { $0.course != nil && $0.round != nil }))) ?? []
        guard !shared.isEmpty else { return [] }
        var byRound: [UUID: (round: Round, holes: [Hole])] = [:]
        for hole in shared {
            guard let round = hole.round else { continue }
            byRound[round.id, default: (round, [])].holes.append(hole)
        }
        for entry in byRound.values {
            let round = entry.round
            for hole in entry.holes { hole.round = nil }
            var owned = Set(round.holes.map(\.number))
            for hole in entry.holes.oneByNumber where owned.insert(hole.number).inserted {
                let id = Hole.roundHoleId(roundId: round.id, number: hole.number)
                let copy = (try? fetch(FetchDescriptor<Hole>(predicate: #Predicate { $0.id == id })))?.first
                    ?? hole.roundCopy(roundId: round.id)
                if !round.holes.contains(where: { $0.id == copy.id }) { round.holes.append(copy) }
            }
        }
        try? save()
        return Array(byRound.keys)
    }

    /// Rounds saved before `currentHoleNumber` existed carry only the old list
    /// position. Resolve it once against the round's own holes; the index is
    /// then zeroed, so this never matches the round again.
    func backfillCurrentHoleNumbers() {
        let stale = (try? fetch(FetchDescriptor<Round>(predicate: #Predicate { $0.currentHoleIndex > 0 }))) ?? []
        guard !stale.isEmpty else { return }
        for round in stale {
            let sorted = round.holesByNumber
            round.currentHoleNumber = sorted.indices.contains(round.currentHoleIndex)
                ? sorted[round.currentHoleIndex].number
                : round.currentHoleIndex + 1
            round.currentHoleIndex = 0
        }
        try? save()
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
    /// The round's own holes, mirroring its `round_holes` rows: copies of the
    /// course's holes (`Hole.roundCopy`), never the course's instances. A
    /// `Hole` belongs to at most one round, so handing a round the course's
    /// holes made the next round at that course crash on insert. Stores that
    /// still share are split at launch (`separateRoundHolesFromCourseHoles`),
    /// which is what makes cascade safe here.
    @Relationship(deleteRule: .cascade, inverse: \Hole.round) var holes: [Hole]
    /// Stored as [Int] (SwiftData support for Set<Int> is flaky); exposed as
    /// Set<Int> via `completedHoles` computed property below.
    var completedHolesArray: [Int]
    /// Legacy: the current hole's position in a device's own sorted hole list.
    /// Read only by `backfillCurrentHoleNumbers`, once, for rounds saved before
    /// `currentHoleNumber` existed. The server keeps its column in step by
    /// trigger for older builds (migration 00051).
    var currentHoleIndex: Int
    /// The hole the round is on, by number: the one value both devices read
    /// for "which hole", resolved against the round's own holes
    /// (`currentHole`). A list position named different holes whenever the two
    /// devices' lists differed.
    var currentHoleNumber: Int = 1
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
        self.currentHoleNumber = holes.map(\.number).min() ?? 1
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

    /// The round's holes in number order.
    var holesByNumber: [Hole] { holes.sorted { $0.number < $1.number } }

    /// The hole the round is on.
    var currentHole: Hole? { holes.first { $0.number == currentHoleNumber } }

    /// The holes before and after `number` in this round, skipping any gap.
    func hole(after number: Int) -> Hole? { holesByNumber.first { $0.number > number } }
    func hole(before number: Int) -> Hole? { holesByNumber.last { $0.number < number } }
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
    let sort_order: Int?
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
