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
final class OSMCourseService {
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
                         completion: @escaping (Result<[OSMCourseCandidate], Error>) -> Void) {
        let radius = radiusMeters ?? defaultRadiusMeters
        let lat = coordinate.latitude
        let lon = coordinate.longitude
        let r = Int(radius)
        ClientEventLogger.log("osm.fetchCandidates.overpassStart", detail: [
            "lat": .double(lat),
            "lon": .double(lon),
            "radius": .integer(r)
        ])
        let query = """
        [out:json][timeout:25];
        (
          way["leisure"="golf_course"]["name"](around:\(r),\(lat),\(lon));
          relation["leisure"="golf_course"]["name"](around:\(r),\(lat),\(lon));
        );
        out tags geom;
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
                    let candidates = try Self.parseCandidates(data: data)
                    ClientEventLogger.log("osm.fetchCandidates.overpassOk", detail: [
                        "candidateCount": .integer(candidates.count)
                    ])
                    completion(.success(candidates))
                } catch {
                    ClientEventLogger.log("osm.fetchCandidates.parseFailed", detail: [
                        "error": .string("\(error)")
                    ])
                    completion(.failure(error))
                }
            }
        }
    }

    /// Second pass — fetch holes/greens/tees/fairways/bunkers inside a course's
    /// bounding polygon. Cache-first by the course's OSM id.
    func fetchCourseGeometry(for candidate: OSMCourseCandidate,
                             completion: @escaping (Result<OSMCourseData, Error>) -> Void) {
        ClientEventLogger.log("osm.fetchGeometry.start", detail: [
            "osmId": .integer(Int(candidate.osmId)),
            "name": .string(candidate.name)
        ])
        // Build a poly:"lat lon lat lon ..." filter from the candidate's
        // bounding polygon. Overpass docs use whitespace-separated lat/lon.
        let polyString = candidate.polygon
            .map { "\($0.latitude) \($0.longitude)" }
            .joined(separator: " ")
        let query = """
        [out:json][timeout:25];
        (
          way["golf"="hole"](poly:"\(polyString)");
          way["golf"="green"](poly:"\(polyString)");
          way["golf"="tee"](poly:"\(polyString)");
          way["golf"="fairway"](poly:"\(polyString)");
          way["golf"="bunker"](poly:"\(polyString)");
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
                        radiusMeters: self?.defaultRadiusMeters ?? 1500
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

    private func executeOverpass(query: String, completion: @escaping (Result<Data, Error>) -> Void) {
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
        var out: [OSMCourseCandidate] = []
        for el in elements {
            guard let type = el["type"] as? String,
                  let osmId = (el["id"] as? Int64) ?? (el["id"] as? Int).map(Int64.init),
                  let tags = el["tags"] as? [String: Any],
                  let name = tags["name"] as? String else { continue }
            // Way: geometry is an array of {lat,lon}.
            // Relation: geometry comes from `out geom` as `bounds` or member geoms;
            // for our purposes, use the relation's bounds OR fall back to the
            // first member with geometry.
            var polygon: [MapPoint] = []
            if type == "way", let geom = el["geometry"] as? [[String: Any]] {
                polygon = geom.compactMap {
                    guard let lat = $0["lat"] as? Double, let lon = $0["lon"] as? Double else { return nil }
                    return MapPoint(latitude: lat, longitude: lon)
                }
            } else if type == "relation" {
                // Concatenate all member ways' geometry into a flat polygon.
                // Imperfect for complex multi-polygon relations but sufficient
                // for the second-pass `(poly:"")` query — Overpass picks up any
                // feature inside the convex hull of the points.
                if let members = el["members"] as? [[String: Any]] {
                    for m in members {
                        if let geom = m["geometry"] as? [[String: Any]] {
                            polygon.append(contentsOf: geom.compactMap {
                                guard let lat = $0["lat"] as? Double, let lon = $0["lon"] as? Double else { return nil }
                                return MapPoint(latitude: lat, longitude: lon)
                            })
                        }
                    }
                }
                // Fallback: many course relations come back from Overpass with
                // no inlined member geometry under `out tags geom;`. The
                // relation still carries a `bounds` rect — use it as a
                // 4-corner polygon. Coarse but the second-pass
                // `(poly:"...")` query just needs an enclosing region, and
                // Wekiva GC (relation 4052767) is an example of one that
                // arrives in this shape. Without this fallback the candidate
                // was silently dropped and we fell through to MapKit /
                // manual mode.
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
            // Centroid = simple average of polygon vertices. Good enough for
            // the picker's "X meters away" sort.
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
                                            radiusMeters: Double) throws -> OSMCourseData {
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

        return OSMCourseData(
            fetchedAt: Date(),
            center: MapPoint(center),
            radiusMeters: radiusMeters,
            holes: holes,
            greens: greens,
            tees: tees,
            fairways: fairways,
            bunkers: bunkers,
            attribution: "Map data © OpenStreetMap contributors (ODbL)"
        )
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

