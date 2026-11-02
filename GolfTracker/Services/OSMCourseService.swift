import Foundation
import CoreLocation

// MARK: - Models

/// One golf hole as tagged in OpenStreetMap. The OSM `way[golf=hole]` is a
/// linestring from tee to green; we also pull `ref` (hole number), `par`, and
/// `handicap` if mappers set them.
struct OSMHole: Codable, Hashable, Identifiable {
    var id = UUID()
    var osmId: Int64
    var ref: String?       // hole number — nil on partially-mapped courses
    var par: Int?
    var handicap: Int?
    var teePoint: MapPoint
    var greenPoint: MapPoint
    var centerline: [MapPoint]
}

/// Generic OSM polygon — used for greens, tees, fairways, bunkers.
struct OSMPolygon: Codable, Hashable, Identifiable {
    var id = UUID()
    var osmId: Int64
    var points: [MapPoint]

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard points.count >= 3 else { return false }
        let x = coordinate.longitude
        let y = coordinate.latitude
        var inside = false
        var j = points.count - 1
        for i in 0..<points.count {
            let xi = points[i].longitude, yi = points[i].latitude
            let xj = points[j].longitude, yj = points[j].latitude
            // Standard ray-casting. The straddle precondition guarantees
            // `(yj - yi) != 0` so no division-by-zero guard is needed.
            // The previous `max((yj - yi), 1.0e-12)` clamp corrupted edges
            // with negative latitude deltas (clockwise winding) — see the
            // matching note in `HoleDetectionBlob.contains`.
            let intersects = ((yi > y) != (yj > y)) &&
                (x < (xj - xi) * (y - yi) / (yj - yi) + xi)
            if intersects { inside.toggle() }
            j = i
        }
        return inside
    }
}

/// A course candidate from the first-pass `leisure=golf_course` Overpass
/// query. Used to populate the picker before we fetch detailed geometry for
/// the course the user actually picked.
struct OSMCourseCandidate: Hashable {
    var osmType: String      // "way" or "relation"
    var osmId: Int64
    var name: String
    var centroid: MapPoint
    var polygon: [MapPoint]  // Course bounding polygon, used to scope the
                             // second-pass holes/greens/tees query.
    /// Sibling polygons from other OSM features that map to the same real
    /// course. Common case: one mapper drew the course as a way under one
    /// name in 2015, another drew a slightly different way under a slightly
    /// different name in 2020, neither cleaned up. We collapse them to one
    /// picker entry but keep all polygons here so the second-pass query
    /// can union them when looking for sub-features.
    var siblingPolygons: [[MapPoint]] = []
    /// The OSM elements those sibling polygons came from, so the server can
    /// fetch them itself when it registers the course.
    var siblings: [OSMElementRef] = []
}

/// One OpenStreetMap element: a way or a relation, by id. The type is left
/// out only when naming a course already registered under that id.
struct OSMElementRef: Hashable, Encodable {
    var type: String? = nil
    let id: Int64
}

/// Bundled OSM data for a single course (after the user has picked which
/// course to play). Tier classification reflects whether the hole numbering
/// is clean enough to start the round on hole 1 with all holes pre-placed.
struct OSMCourseData: Codable, Hashable {
    enum Tier: String, Codable {
        /// Hole refs are exactly {1, 2, ..., N} — pure integers, no duplicates,
        /// contiguous, every hole accounted for. Round starts on hole 1 with
        /// all N holes pre-placed.
        case full
        /// Greens are present but hole numbering isn't clean (duplicates,
        /// gaps, non-integer refs, or umbrella mappings like Bethpage State
        /// Park where 90 holes share one polygon). UI uses OSM polygons in
        /// place of blob detection but user still picks per-hole as they go.
        case partial
        /// No green polygons usable — fall back to MapKit blob detection.
        case none
    }

    var fetchedAt: Date
    var center: MapPoint
    var radiusMeters: Double
    var holes: [OSMHole]
    var greens: [OSMPolygon]
    var tees: [OSMPolygon]
    var fairways: [OSMPolygon]
    var bunkers: [OSMPolygon]
    var attribution: String
    /// Course-level bounding polygon (assembled from the OSM relation's
    /// outer-role member ways, or the way's own outline). Used to scope the
    /// blob detection analyzer so two courses sharing one resort property
    /// (Stonegate Cypress vs Oaks) don't cross-contaminate detection.
    /// Optional for backward compat — old osm_polygons jsonb rows lack it.
    /// Includes sibling polygons from grouped duplicates as a flat union;
    /// containment test uses any-polygon-contains semantics.
    var boundingPolygons: [[MapPoint]]?

    /// "Clean" iff every hole has a pure-integer ref, refs are unique, and they
    /// form a contiguous 1..N sequence. Bethpage umbrellas fail (5x dups);
    /// Pinehurst polygon-overlap cases fail (1 dup); Hyde Park passes.
    var tier: Tier {
        if greens.isEmpty { return .none }
        let intRefs = holes.compactMap { h -> Int? in
            guard let ref = h.ref, !ref.isEmpty, let n = Int(ref) else { return nil }
            return n
        }
        guard intRefs.count == holes.count, !intRefs.isEmpty else { return .partial }
        let unique = Set(intRefs)
        guard unique.count == intRefs.count else { return .partial }   // duplicates
        let expected = Set(1...intRefs.count)
        return unique == expected ? .full : .partial                   // contiguous?
    }

    /// For a given hole, find the green polygon whose interior contains the
    /// hole's `greenPoint`. Used to bind line-based hole records to polygon
    /// geometry without an explicit OSM relationship.
    func greenPolygon(for hole: OSMHole) -> OSMPolygon? {
        let coord = hole.greenPoint.coordinate
        return greens.first { $0.contains(coord) }
    }
}

// MARK: - Service

/// Hand-rolled Overpass client. Both phone and watch can call directly — no
/// WatchConnectivity hop required.
///
/// **Caching note**: there is no separate cache table any more. Polygon data
/// for a registered course is persisted on the shared `courses.osm_polygons`
/// JSONB column (see migration 00026). RoundResolver reads it directly from
/// the row when the user picks an existing shared course, so this service
/// only sees Overpass calls for courses that haven't been registered yet.
final class OSMCourseService: Sendable {
    static let shared = OSMCourseService()

    private let overpassEndpoint = "https://overpass-api.de/api/interpreter"
    private let defaultRadiusMeters: Double = 1500

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - High-level resolve (two-pass: candidates → picked course geometry)

    /// First pass — fetch named `leisure=golf_course` features near the GPS
    /// point. Returns a candidate list for the resolver/picker to choose from.
    /// Each candidate carries its bounding polygon for the second-pass query.
    func fetchCandidates(near coordinate: CLLocationCoordinate2D,
                         radiusMeters: Double? = nil,
                         completion: @escaping @Sendable (Result<[OSMCourseCandidate], Error>) -> Void) {
        let radius = radiusMeters ?? defaultRadiusMeters
        let lat = coordinate.latitude
        let lon = coordinate.longitude
        let r = Int(radius)
        ClientEventLogger.log("osm.fetchCandidates.overpassStart", detail: [
            "lat": .double(lat),
            "lon": .double(lon),
            "radius": .integer(r)
        ])
        // `(_;>;)` recurses into relation members so we get their member
        // ways' geometry inline. Without this, relations come back as
        // bbox rectangles only — useless for telling apart Stonegate
        // Cypress vs Oaks Course (same physical property, different
        // course outlines, two relations sharing one bbox).
        let query = """
        [out:json][timeout:25];
        (
          way["leisure"="golf_course"]["name"](around:\(r),\(lat),\(lon));
          relation["leisure"="golf_course"]["name"](around:\(r),\(lat),\(lon));
        )->.cs;
        .cs out tags;
        (.cs;>;);
        out body geom;
        """
        executeOverpass(query: query) { result in
            switch result {
            case .failure(let e):
                ClientEventLogger.log("osm.fetchCandidates.overpassFailed", detail: [
                    "error": .string("\(e)")
                ])
                completion(.failure(e))
            case .success(let data):
                do {
                    let raw = try Self.parseCandidates(data: data)
                    // Collapse near-duplicate OSM features that all describe
                    // the same real-world course (multiple ways/relations
                    // tagged with similar names by different mappers over
                    // the years; some empty, some populated). One picker
                    // entry per real course, with sibling polygons kept so
                    // the second-pass sub-feature query can union them.
                    let grouped = Self.groupCandidates(raw)
                    ClientEventLogger.log("osm.fetchCandidates.overpassOk", detail: [
                        "candidateCount": .integer(grouped.count),
                        "rawCount": .integer(raw.count)
                    ])
                    completion(.success(grouped))
                } catch {
                    ClientEventLogger.log("osm.fetchCandidates.parseFailed", detail: [
                        "error": .string("\(error)")
                    ])
                    completion(.failure(error))
                }
            }
        }
    }

    /// Cluster raw OSM candidates that describe the same real-world course.
    /// Two candidates are "the same course" when their centroids are within
    /// `clusterDistanceMeters` AND their stripped names share a discriminating
    /// token (using the same strip rules as the GCAPI scorecard search).
    /// Picks the canonical entry per cluster as the one with the largest
    /// polygon (best geometry coverage), falls back to the longest name.
    static let clusterDistanceMeters: Double = 500
    private static func groupCandidates(_ raw: [OSMCourseCandidate]) -> [OSMCourseCandidate] {
        var clusters: [[OSMCourseCandidate]] = []
        outer: for cand in raw {
            let candTokens = strippedTokens(cand.name)
            for i in 0..<clusters.count {
                guard let head = clusters[i].first else { continue }
                let dist = distanceMeters(head.centroid, cand.centroid)
                if dist > clusterDistanceMeters { continue }
                let headTokens = strippedTokens(head.name)
                if !candTokens.isDisjoint(with: headTokens) {
                    clusters[i].append(cand)
                    continue outer
                }
            }
            clusters.append([cand])
        }
        return clusters.map { group -> OSMCourseCandidate in
            // Canonical: largest polygon wins (best geometry); tie → longest name.
            let canonical = group.max { l, r in
                if l.polygon.count != r.polygon.count { return l.polygon.count < r.polygon.count }
                return l.name.count < r.name.count
            } ?? group[0]
            let others = group.filter { $0.osmId != canonical.osmId }
            var out = canonical
            out.siblingPolygons = others.map { $0.polygon }
            out.siblings = others.map { OSMElementRef(type: $0.osmType, id: $0.osmId) }
            return out
        }
    }

    /// Strip the same noise words the scorecard search uses, so candidates
    /// that share the discriminating proper noun cluster together regardless
    /// of "Country Club" vs "Golf Club" vs "Golf Course" suffix differences.
    private static let osmNameStop: Set<String> = ["the","of","and","at","on","in","a","an","&"]
    private static let osmNameJargon: Set<String> = [
        "country","club","golf","course","courses","resort","national",
        "international","municipal","championship","executive","public",
        "gc","cc","center","centre"
    ]
    private static func strippedTokens(_ name: String) -> Set<String> {
        var s = name.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[^\w\s'-]"#, with: " ", options: .regularExpression)
        let toks = s.lowercased().split(whereSeparator: { $0.isWhitespace })
            .map { t -> String in var x = String(t); if x.hasSuffix("'s") { x.removeLast(2) }; return x }
            .filter { !$0.isEmpty && !osmNameStop.contains($0) && !osmNameJargon.contains($0) }
        return Set(toks)
    }

    private static func distanceMeters(_ a: MapPoint, _ b: MapPoint) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// `fetchCandidates`, awaited.
    func fetchCandidates(near coordinate: CLLocationCoordinate2D,
                         radiusMeters: Double? = nil) async -> Result<[OSMCourseCandidate], Error> {
        await withCheckedContinuation { cont in
            fetchCandidates(near: coordinate, radiusMeters: radiusMeters) { cont.resume(returning: $0) }
        }
    }

    /// `fetchCourseGeometry`, awaited.
    func fetchCourseGeometry(for candidate: OSMCourseCandidate) async -> Result<OSMCourseData, Error> {
        await withCheckedContinuation { cont in
            fetchCourseGeometry(for: candidate) { cont.resume(returning: $0) }
        }
    }

    /// Second pass — fetch holes/greens/tees/fairways/bunkers inside a course's
    /// bounding polygon. Cache-first by the course's OSM id.
    func fetchCourseGeometry(for candidate: OSMCourseCandidate,
                             completion: @escaping @Sendable (Result<OSMCourseData, Error>) -> Void) {
        ClientEventLogger.log("osm.fetchGeometry.start", detail: [
            "osmId": .integer(Int(candidate.osmId)),
            "name": .string(candidate.name)
        ])
        // Build a `poly:"lat lon lat lon ..."` filter for EACH candidate
        // polygon (canonical + siblings) and union them. Overpass evaluates
        // each (poly:...) clause against the input set, so combining them in
        // a `(...);` group is a logical OR. The grouping at fetchCandidates
        // collapsed duplicate course features into one picker entry; here we
        // gather sub-features inside the union of all those features'
        // bounding polygons so we don't lose mapper-split coverage.
        let allPolygons = ([candidate.polygon] + candidate.siblingPolygons).filter { !$0.isEmpty }
        var clauses: [String] = []
        for poly in allPolygons {
            let polyString = poly.map { "\($0.latitude) \($0.longitude)" }.joined(separator: " ")
            for tag in ["hole","green","tee","fairway","bunker"] {
                clauses.append(#"way["golf"="\#(tag)"](poly:"\#(polyString)");"#)
            }
        }
        let query = """
        [out:json][timeout:25];
        (
        \(clauses.joined(separator: "\n  "))
        );
        out tags geom;
        """
        executeOverpass(query: query) { [weak self] result in
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success(let data):
                do {
                    let parsed = try Self.parseCourseGeometry(
                        data: data,
                        center: candidate.centroid.coordinate,
                        radiusMeters: self?.defaultRadiusMeters ?? 1500,
                        boundingPolygons: ([candidate.polygon] + candidate.siblingPolygons).filter { !$0.isEmpty }
                    )
                    ClientEventLogger.log("osm.fetchGeometry.ok", detail: [
                        "osmId": .integer(Int(candidate.osmId)),
                        "holeCount": .integer(parsed.holes.count),
                        "greenCount": .integer(parsed.greens.count)
                    ])
                    completion(.success(parsed))
                } catch {
                    ClientEventLogger.log("osm.fetchGeometry.parseFailed", detail: [
                        "osmId": .integer(Int(candidate.osmId)),
                        "error": .string("\(error)")
                    ])
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Overpass transport

    private func executeOverpass(query: String, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        guard let url = URL(string: overpassEndpoint) else {
            completion(.failure(OSMError.badURL)); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "data=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        req.httpBody = body.data(using: .utf8)
        session.dataTask(with: req) { data, response, error in
            if let error = error { completion(.failure(error)); return }
            guard let data = data else { completion(.failure(OSMError.emptyResponse)); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status >= 200 && status < 300 else {
                completion(.failure(OSMError.httpStatus(status))); return
            }
            completion(.success(data))
        }.resume()
    }

    private static func parseCandidates(data: Data) throws -> [OSMCourseCandidate] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = json["elements"] as? [[String: Any]] else {
            throw OSMError.parseFailure
        }
        // Index ways by id so we can resolve relation members → polygons.
        // The Overpass query uses `(_;>;)` recursion, so all member ways
        // come back at the top level alongside the named relations.
        var wayPolygonById: [Int64: [MapPoint]] = [:]
        for el in elements where (el["type"] as? String) == "way" {
            guard let id = (el["id"] as? Int64) ?? (el["id"] as? Int).map(Int64.init),
                  let geom = el["geometry"] as? [[String: Any]] else { continue }
            let pts: [MapPoint] = geom.compactMap {
                guard let lat = $0["lat"] as? Double, let lon = $0["lon"] as? Double else { return nil }
                return MapPoint(latitude: lat, longitude: lon)
            }
            if !pts.isEmpty { wayPolygonById[id] = pts }
        }

        var out: [OSMCourseCandidate] = []
        for el in elements {
            guard let type = el["type"] as? String,
                  let osmId = (el["id"] as? Int64) ?? (el["id"] as? Int).map(Int64.init),
                  let tags = el["tags"] as? [String: Any],
                  let name = tags["name"] as? String,
                  (tags["leisure"] as? String) == "golf_course" else { continue }
            var polygon: [MapPoint] = []
            if type == "way", let geom = el["geometry"] as? [[String: Any]] {
                // Way: inline geometry.
                polygon = geom.compactMap {
                    guard let lat = $0["lat"] as? Double, let lon = $0["lon"] as? Double else { return nil }
                    return MapPoint(latitude: lat, longitude: lon)
                }
            } else if type == "relation" {
                // Relation: assemble polygon from member ways. Members
                // reference ways by id; we resolved those above. Outer
                // members go first, inner (holes in the polygon) are
                // ignored — for analyzer scoping we want the bounding
                // outer outline, not the donut topology.
                if let members = el["members"] as? [[String: Any]] {
                    for m in members {
                        let role = (m["role"] as? String) ?? ""
                        guard role == "outer" || role.isEmpty,
                              (m["type"] as? String) == "way",
                              let ref = (m["ref"] as? Int64) ?? (m["ref"] as? Int).map(Int64.init),
                              let pts = wayPolygonById[ref] else { continue }
                        polygon.append(contentsOf: pts)
                    }
                }
                // Last-resort fallback: the relation has bounds but no
                // resolvable member geometry. A 4-corner bbox is coarse
                // (covers neighbouring courses on the same property) but
                // beats dropping the candidate entirely.
                if polygon.isEmpty, let bounds = el["bounds"] as? [String: Any],
                   let minLat = bounds["minlat"] as? Double,
                   let minLon = bounds["minlon"] as? Double,
                   let maxLat = bounds["maxlat"] as? Double,
                   let maxLon = bounds["maxlon"] as? Double {
                    polygon = [
                        MapPoint(latitude: minLat, longitude: minLon),
                        MapPoint(latitude: minLat, longitude: maxLon),
                        MapPoint(latitude: maxLat, longitude: maxLon),
                        MapPoint(latitude: maxLat, longitude: minLon),
                    ]
                }
            }
            guard polygon.count >= 3 else { continue }
            let avgLat = polygon.map(\.latitude).reduce(0, +) / Double(polygon.count)
            let avgLon = polygon.map(\.longitude).reduce(0, +) / Double(polygon.count)
            out.append(OSMCourseCandidate(
                osmType: type,
                osmId: osmId,
                name: name,
                centroid: MapPoint(latitude: avgLat, longitude: avgLon),
                polygon: polygon
            ))
        }
        return out
    }

    private static func parseCourseGeometry(data: Data,
                                            center: CLLocationCoordinate2D,
                                            radiusMeters: Double,
                                            boundingPolygons: [[MapPoint]]? = nil) throws -> OSMCourseData {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = json["elements"] as? [[String: Any]] else {
            throw OSMError.parseFailure
        }

        var holes: [OSMHole] = []
        var greens: [OSMPolygon] = []
        var tees: [OSMPolygon] = []
        var fairways: [OSMPolygon] = []
        var bunkers: [OSMPolygon] = []

        for el in elements {
            guard let type = el["type"] as? String, type == "way",
                  let osmId = el["id"] as? Int64 ?? (el["id"] as? Int).map(Int64.init),
                  let tags = el["tags"] as? [String: Any],
                  let golfTag = tags["golf"] as? String,
                  let geometry = el["geometry"] as? [[String: Any]] else { continue }

            let points: [MapPoint] = geometry.compactMap { pt in
                guard let lat = pt["lat"] as? Double, let lon = pt["lon"] as? Double else { return nil }
                return MapPoint(latitude: lat, longitude: lon)
            }
            guard !points.isEmpty else { continue }

            switch golfTag {
            case "hole":
                guard let first = points.first, let last = points.last else { continue }
                let hole = OSMHole(
                    osmId: osmId,
                    ref: tags["ref"] as? String,
                    par: (tags["par"] as? String).flatMap(Int.init),
                    handicap: (tags["handicap"] as? String).flatMap(Int.init),
                    teePoint: first,
                    greenPoint: last,
                    centerline: points
                )
                holes.append(hole)
            case "green":
                greens.append(OSMPolygon(osmId: osmId, points: points))
            case "tee":
                tees.append(OSMPolygon(osmId: osmId, points: points))
            case "fairway":
                fairways.append(OSMPolygon(osmId: osmId, points: points))
            case "bunker":
                bunkers.append(OSMPolygon(osmId: osmId, points: points))
            default:
                continue
            }
        }

        // Centroid-dedup at 3m. With sibling polygons unioned in the
        // Overpass query, two mappers tagging the same physical green can
        // come back as two near-identical OSMPolygons. 3m is well below
        // any real course-feature spacing and well above OSM coordinate
        // jitter, so it cleanly removes mapper-collision dupes without
        // collapsing legitimately-adjacent features.
        return OSMCourseData(
            fetchedAt: Date(),
            center: MapPoint(center),
            radiusMeters: radiusMeters,
            holes: dedupHoles(holes),
            greens: dedupPolygons(greens),
            tees: dedupPolygons(tees),
            fairways: dedupPolygons(fairways),
            bunkers: dedupPolygons(bunkers),
            attribution: "Map data © OpenStreetMap contributors (ODbL)",
            boundingPolygons: boundingPolygons
        )
    }

    private static let subFeatureDedupMeters: Double = 3.0

    private static func centroid(_ points: [MapPoint]) -> MapPoint? {
        guard !points.isEmpty else { return nil }
        let lat = points.map(\.latitude).reduce(0, +) / Double(points.count)
        let lon = points.map(\.longitude).reduce(0, +) / Double(points.count)
        return MapPoint(latitude: lat, longitude: lon)
    }

    private static func dedupPolygons(_ polys: [OSMPolygon]) -> [OSMPolygon] {
        var keptCentroids: [MapPoint] = []
        var out: [OSMPolygon] = []
        for p in polys {
            guard let c = centroid(p.points) else { continue }
            let dup = keptCentroids.contains { distanceMeters($0, c) <= subFeatureDedupMeters }
            if !dup { keptCentroids.append(c); out.append(p) }
        }
        return out
    }

    private static func dedupHoles(_ holes: [OSMHole]) -> [OSMHole] {
        var keptCentroids: [MapPoint] = []
        var out: [OSMHole] = []
        for h in holes {
            guard let c = centroid(h.centerline) else { continue }
            let dup = keptCentroids.contains { distanceMeters($0, c) <= subFeatureDedupMeters }
            if !dup { keptCentroids.append(c); out.append(h) }
        }
        return out
    }
}

// MARK: - Errors

enum OSMError: Error, LocalizedError {
    case badURL
    case emptyResponse
    case httpStatus(Int)
    case parseFailure

    var errorDescription: String? {
        switch self {
        case .badURL: return "Bad Overpass URL"
        case .emptyResponse: return "Empty Overpass response"
        case .httpStatus(let code): return "Overpass HTTP \(code)"
        case .parseFailure: return "Could not parse Overpass JSON"
        }
    }
}

