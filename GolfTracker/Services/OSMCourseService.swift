import Foundation
import CoreLocation
import Supabase

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
            let intersects = ((yi > y) != (yj > y)) &&
                (x < ((xj - xi) * (y - yi) / max((yj - yi), 1.0e-12)) + xi)
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

/// Hand-rolled Overpass + Supabase cache client. Both phone and watch can call
/// `resolve(near:)` directly — no WatchConnectivity hop required.
///
/// Cache strategy: bucket the GPS center to 0.01° (~1.1km) so users at the same
/// course collide on the same cache entry. Bucket lookup is O(1) on a unique
/// index. On miss, fetch from Overpass and upsert.
final class OSMCourseService {
    static let shared = OSMCourseService()

    private let overpassEndpoint = "https://overpass-api.de/api/interpreter"
    private let defaultRadiusMeters: Double = 1500
    private let cacheTTL: TimeInterval = 60 * 60 * 24 * 90  // 90 days

    private let session: URLSession
    private let supabase = SupabaseManager.shared

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    private func currentUserId() -> String? {
        #if os(watchOS)
        return WatchAuthSession.shared.session?.userId
        #else
        return AuthManager.shared.currentUserId
        #endif
    }

    // MARK: - High-level resolve (two-pass: candidates → picked course geometry)

    private func isExpired(_ data: OSMCourseData) -> Bool {
        Date().timeIntervalSince(data.fetchedAt) > cacheTTL
    }

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
        fetchFromCache(osmId: candidate.osmId) { [weak self] cached in
            guard let self = self else { return }
            if let cached = cached, !self.isExpired(cached) {
                ClientEventLogger.log("osm.fetchGeometry.cacheHit", detail: [
                    "osmId": .integer(Int(candidate.osmId))
                ])
                completion(.success(cached))
                return
            }
            ClientEventLogger.log("osm.fetchGeometry.cacheMiss", detail: [
                "osmId": .integer(Int(candidate.osmId)),
                "expired": .bool(cached != nil)
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
            self.executeOverpass(query: query) { [weak self] result in
                switch result {
                case .failure(let e): completion(.failure(e))
                case .success(let data):
                    do {
                        let parsed = try Self.parseCourseGeometry(
                            data: data,
                            center: candidate.centroid.coordinate,
                            radiusMeters: self?.defaultRadiusMeters ?? 1500
                        )
                        completion(.success(parsed))
                        // Fire-and-forget cache write keyed by OSM id.
                        ClientEventLogger.log("osm.fetchGeometry.upsertStart", detail: [
                            "osmId": .integer(Int(candidate.osmId)),
                            "holeCount": .integer(parsed.holes.count),
                            "greenCount": .integer(parsed.greens.count)
                        ])
                        self?.upsertCache(parsed, osmId: candidate.osmId) { ok in
                            ClientEventLogger.log(
                                ok ? "osm.fetchGeometry.upsertOk" : "osm.fetchGeometry.upsertFailed",
                                detail: ["osmId": .integer(Int(candidate.osmId))]
                            )
                        }
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

    // MARK: - Supabase cache

    /// Cache row by OSM course id. We embed osmId into gps_bucket_lat as a
    /// negative-sentinel sigil so we don't need a new column on osm_course_data:
    /// the schema's UNIQUE(gps_bucket_lat, gps_bucket_lon) suffices when we use
    /// (osmId-derived) keys outside the real lat/lon range.
    private func cacheKey(forOsmId id: Int64) -> (lat: Double, lon: Double) {
        // OSM ids are always positive integers up to ~10^11. Stuff them into
        // both columns: bucket_lat = -1 (sentinel for "OSM keyed"), bucket_lon = id.
        // Real coordinates are always lat ∈ [-90,90], so -1 lat collides with
        // nothing real, and lon = (e.g.) 286113630 is wildly outside [-180,180].
        return (lat: -1.0, lon: Double(id))
    }

    private func bucketKey(for coordinate: CLLocationCoordinate2D) -> (lat: Double, lon: Double) {
        // Round to 0.01° (~1.1km) — used by the first-pass query when we don't
        // yet know an OSM course id (vestigial; kept for back-compat).
        let lat = (coordinate.latitude * 100).rounded() / 100
        let lon = (coordinate.longitude * 100).rounded() / 100
        return (lat, lon)
    }

    /// Row shape we read out of `osm_course_data`. Only `data` is decoded into
    /// `OSMCourseData`; the rest of the columns are managed by the migration.
    private struct CacheRow: Decodable {
        let data: OSMCourseData
    }

    func fetchFromCache(near coordinate: CLLocationCoordinate2D,
                        completion: @escaping (OSMCourseData?) -> Void) {
        let bucket = bucketKey(for: coordinate)
        fetchFromCache(bucketLat: bucket.lat, bucketLon: bucket.lon, completion: completion)
    }

    func fetchFromCache(osmId: Int64,
                        completion: @escaping (OSMCourseData?) -> Void) {
        let key = cacheKey(forOsmId: osmId)
        fetchFromCache(bucketLat: key.lat, bucketLon: key.lon, completion: completion)
    }

    private func fetchFromCache(bucketLat: Double, bucketLon: Double,
                                completion: @escaping (OSMCourseData?) -> Void) {
        Task {
            do {
                let rows: [CacheRow] = try await supabase.from("osm_course_data")
                    .select("data,fetched_at")
                    .eq("gps_bucket_lat", value: bucketLat)
                    .eq("gps_bucket_lon", value: bucketLon)
                    .limit(1)
                    .execute()
                    .value
                completion(rows.first?.data)
            } catch {
                dprint("[OSMCourseService] cache fetch failed: \(error)")
                completion(nil)
            }
        }
    }

    /// Upsert payload — encoded as the row shape the table expects.
    private struct CacheUpsert: Encodable {
        let gps_bucket_lat: Double
        let gps_bucket_lon: Double
        let center_latitude: Double
        let center_longitude: Double
        let radius_meters: Int
        let fetched_at: Date
        let attribution: String
        let course_id: String?
        let created_by: String?
        let data: OSMCourseData
    }

    func upsertCache(_ data: OSMCourseData,
                     osmId: Int64,
                     completion: @escaping (Bool) -> Void) {
        let key = cacheKey(forOsmId: osmId)
        upsertRow(data, bucketLat: key.lat, bucketLon: key.lon, courseId: nil, completion: completion)
    }

    func upsertCache(_ data: OSMCourseData,
                     courseId: UUID?,
                     completion: @escaping (Bool) -> Void) {
        let bucket = bucketKey(for: data.center.coordinate)
        upsertRow(data, bucketLat: bucket.lat, bucketLon: bucket.lon, courseId: courseId, completion: completion)
    }

    private func upsertRow(_ data: OSMCourseData,
                           bucketLat: Double, bucketLon: Double,
                           courseId: UUID?,
                           completion: @escaping (Bool) -> Void) {
        let row = CacheUpsert(
            gps_bucket_lat: bucketLat,
            gps_bucket_lon: bucketLon,
            center_latitude: data.center.latitude,
            center_longitude: data.center.longitude,
            radius_meters: Int(data.radiusMeters),
            fetched_at: data.fetchedAt,
            attribution: data.attribution,
            course_id: courseId?.uuidString,
            created_by: currentUserId(),
            data: data
        )
        Task {
            do {
                try await supabase.from("osm_course_data")
                    .upsert(row, onConflict: "gps_bucket_lat,gps_bucket_lon")
                    .execute()
                completion(true)
            } catch {
                ClientEventLogger.log("osm.upsertRow.threw", detail: [
                    "error": .string("\(error)"),
                    "bucketLat": .double(bucketLat),
                    "bucketLon": .double(bucketLon)
                ])
                dprint("[OSMCourseService] cache upsert failed: \(error)")
                completion(false)
            }
        }
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

// MARK: - JSON helpers

private extension JSONEncoder {
    static let osm: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let osm: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
