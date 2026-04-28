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
            let intersects = ((yi > y) != (yj > y)) &&
                (x < ((xj - xi) * (y - yi) / max((yj - yi), 1.0e-12)) + xi)
            if intersects { inside.toggle() }
            j = i
        }
        return inside
    }
}

/// Bundled OSM data for a course area, tier-classified.
struct OSMCourseData: Codable, Hashable {
    enum Tier: String, Codable {
        /// All (or nearly all) holes have `ref` numbers AND green polygons —
        /// round can start with full hole numbering and no manual labeling.
        case full
        /// Greens are present but holes aren't numbered — UI uses OSM polygons
        /// instead of blob detection, but user still picks per-hole.
        case partial
        /// Nothing usable — fall back to MapKit blob detection.
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

    /// Computed tier classification. Considers a course "full" when at least 9
    /// holes have ref numbers AND we have a green polygon for at least 75% of
    /// numbered holes (point-in-polygon match against hole.greenPoint).
    var tier: Tier {
        if greens.isEmpty { return .none }
        let numbered = holes.filter { ($0.ref ?? "").isEmpty == false && Int($0.ref ?? "") != nil }
        if numbered.count < 9 { return .partial }
        var matched = 0
        for hole in numbered {
            let coord = hole.greenPoint.coordinate
            if greens.contains(where: { $0.contains(coord) }) { matched += 1 }
        }
        let coverage = Double(matched) / Double(numbered.count)
        return coverage >= 0.75 ? .full : .partial
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

    // Inline Supabase config so this file compiles on both iOS and watchOS
    // without depending on SupabaseClient/AuthManager (iOS-only today).
    // Will move to a shared client when we migrate to supabase-swift SDK.
    private let projectURL = "https://oumnicnvayqrbfbljgyl.supabase.co"
    private let anonKey = "sb_publishable_i0loB-AZw2qGokBJzHGSKA_VGgAgjBi"

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    private func currentAccessToken() -> String? {
        #if os(watchOS)
        return WatchAuthSession.shared.session?.accessToken
        #else
        return AuthManager.shared.currentAccessToken
        #endif
    }

    private func currentUserId() -> String? {
        #if os(watchOS)
        return WatchAuthSession.shared.session?.userId
        #else
        return AuthManager.shared.currentUserId
        #endif
    }

    private func authedRequest(path: String, method: String = "GET", body: Data? = nil) -> URLRequest? {
        guard let url = URL(string: "\(projectURL)\(path)") else { return nil }
        let token = currentAccessToken() ?? anonKey
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return req
    }

    // MARK: - High-level resolve

    /// Cache-first lookup. Hits Supabase cache for the GPS bucket; on miss,
    /// fetches from Overpass and writes the result back to the cache.
    func resolve(near coordinate: CLLocationCoordinate2D,
                 courseId: UUID? = nil,
                 radiusMeters: Double? = nil,
                 completion: @escaping (Result<OSMCourseData, Error>) -> Void) {
        let radius = radiusMeters ?? defaultRadiusMeters
        fetchFromCache(near: coordinate) { [weak self] cached in
            guard let self = self else { return }
            if let cached = cached, !self.isExpired(cached) {
                completion(.success(cached))
                return
            }
            self.fetchFromOverpass(near: coordinate, radiusMeters: radius) { [weak self] result in
                if case .success(let data) = result {
                    self?.upsertCache(data, courseId: courseId) { _ in }
                }
                completion(result)
            }
        }
    }

    private func isExpired(_ data: OSMCourseData) -> Bool {
        Date().timeIntervalSince(data.fetchedAt) > cacheTTL
    }

    // MARK: - Overpass

    func fetchFromOverpass(near coordinate: CLLocationCoordinate2D,
                           radiusMeters: Double,
                           completion: @escaping (Result<OSMCourseData, Error>) -> Void) {
        let lat = coordinate.latitude
        let lon = coordinate.longitude
        let r = Int(radiusMeters)
        let query = """
        [out:json][timeout:25];
        (
          way["golf"="green"](around:\(r),\(lat),\(lon));
          way["golf"="tee"](around:\(r),\(lat),\(lon));
          way["golf"="fairway"](around:\(r),\(lat),\(lon));
          way["golf"="bunker"](around:\(r),\(lat),\(lon));
          way["golf"="hole"](around:\(r),\(lat),\(lon));
        );
        out tags geom;
        """

        guard let url = URL(string: overpassEndpoint) else {
            completion(.failure(OSMError.badURL)); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "data=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        req.httpBody = body.data(using: .utf8)

        session.dataTask(with: req) { [weak self] data, response, error in
            if let error = error { completion(.failure(error)); return }
            guard let data = data else { completion(.failure(OSMError.emptyResponse)); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status >= 200 && status < 300 else {
                completion(.failure(OSMError.httpStatus(status)))
                return
            }
            do {
                let parsed = try self?.parseOverpassResponse(data: data,
                                                             center: coordinate,
                                                             radiusMeters: radiusMeters)
                if let parsed = parsed {
                    completion(.success(parsed))
                } else {
                    completion(.failure(OSMError.parseFailure))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private func parseOverpassResponse(data: Data,
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

    // MARK: - Supabase cache (hand-rolled REST; will move to SDK with the rest)

    private func bucketKey(for coordinate: CLLocationCoordinate2D) -> (lat: Double, lon: Double) {
        // Round to 0.01° (~1.1km) so users at the same course collide on the same row.
        let lat = (coordinate.latitude * 100).rounded() / 100
        let lon = (coordinate.longitude * 100).rounded() / 100
        return (lat, lon)
    }

    func fetchFromCache(near coordinate: CLLocationCoordinate2D,
                        completion: @escaping (OSMCourseData?) -> Void) {
        let bucket = bucketKey(for: coordinate)
        let path = "/rest/v1/osm_course_data?gps_bucket_lat=eq.\(bucket.lat)&gps_bucket_lon=eq.\(bucket.lon)&select=data,fetched_at&limit=1"
        guard let req = authedRequest(path: path, method: "GET") else {
            completion(nil); return
        }
        session.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let row = arr.first,
                  let blob = row["data"] else {
                completion(nil); return
            }
            do {
                let blobData = try JSONSerialization.data(withJSONObject: blob)
                let decoded = try JSONDecoder.osm.decode(OSMCourseData.self, from: blobData)
                completion(decoded)
            } catch {
                completion(nil)
            }
        }.resume()
    }

    func upsertCache(_ data: OSMCourseData,
                     courseId: UUID?,
                     completion: @escaping (Bool) -> Void) {
        let bucket = bucketKey(for: data.center.coordinate)
        var payload: [String: Any] = [
            "gps_bucket_lat": bucket.lat,
            "gps_bucket_lon": bucket.lon,
            "center_latitude": data.center.latitude,
            "center_longitude": data.center.longitude,
            "radius_meters": Int(data.radiusMeters),
            "fetched_at": ISO8601DateFormatter().string(from: data.fetchedAt),
            "attribution": data.attribution
        ]
        if let courseId = courseId {
            payload["course_id"] = courseId.uuidString
        }
        if let userId = currentUserId() {
            payload["created_by"] = userId
        }
        // Encode the OSM dump as a JSONB-compatible object.
        if let blob = try? JSONEncoder.osm.encode(data),
           let obj = try? JSONSerialization.jsonObject(with: blob) {
            payload["data"] = obj
        }

        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              var req = authedRequest(
                path: "/rest/v1/osm_course_data?on_conflict=gps_bucket_lat,gps_bucket_lon",
                method: "POST",
                body: body
              ) else {
            completion(false); return
        }
        req.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        session.dataTask(with: req) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            completion(status >= 200 && status < 300)
        }.resume()
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
