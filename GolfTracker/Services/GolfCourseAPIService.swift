import Foundation
import CoreLocation
import Supabase

// MARK: - Wire types (match Edge Function response shape)

/// One tee box's worth of scorecard data, as returned by GolfCourseAPI via the
/// Edge Function. Matches the API's response shape — not a domain model.
struct GCAPITeeBox: Codable, Hashable {
    let tee_name: String
    let course_rating: Double?
    let slope_rating: Int?
    let bogey_rating: Double?
    let total_yards: Int?
    let total_meters: Int?
    let number_of_holes: Int?
    let par_total: Int?
    let front_course_rating: Double?
    let front_slope_rating: Int?
    let front_bogey_rating: Double?
    let back_course_rating: Double?
    let back_slope_rating: Int?
    let back_bogey_rating: Double?
    let holes: [GCAPIHole]?
}

struct GCAPIHole: Codable, Hashable {
    let par: Int?
    let yardage: Int?
    let handicap: Int?
}

struct GCAPILocation: Codable, Hashable {
    let address: String?
    let city: String?
    let state: String?
    let country: String?
    let latitude: Double?
    let longitude: Double?
}

struct GCAPITees: Codable, Hashable {
    let female: [GCAPITeeBox]?
    let male: [GCAPITeeBox]?
}

/// One course as returned by the GolfCourseAPI search/lookup. Carries enough
/// detail (tees + per-hole data) to drive both the resolver match step and
/// the tee-picker UI without a follow-up fetch.
struct GCAPICourse: Codable, Hashable, Identifiable {
    let id: Int
    let club_name: String?
    let course_name: String?
    let location: GCAPILocation?
    let tees: GCAPITees?

    /// Display name used in the picker UI. Falls back through club_name and
    /// course_name; usually one or both are present.
    var displayName: String {
        switch (club_name, course_name) {
        case let (club?, course?) where club == course: return club
        case let (club?, course?): return "\(club) — \(course)"
        case let (club?, nil): return club
        case let (nil, course?): return course
        case (nil, nil): return "Unknown course"
        }
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let lat = location?.latitude, let lon = location?.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Flat list of every tee box (female + male combined), tagged with gender.
    var allTees: [(box: GCAPITeeBox, gender: String)] {
        var out: [(GCAPITeeBox, String)] = []
        out.append(contentsOf: (tees?.female ?? []).map { ($0, "female") })
        out.append(contentsOf: (tees?.male ?? []).map { ($0, "male") })
        return out
    }
}

private struct GCAPISearchResponse: Codable {
    let courses: [GCAPICourse]?
}

// MARK: - Cached tee row (read from course_tees + course_tee_holes)

/// Stored representation of a tee box, fetched from the DB cache after the
/// Edge Function has populated it. UI consumes this via the tee picker.
struct CachedCourseTee: Identifiable, Hashable, Codable {
    let id: UUID
    let courseId: UUID?
    let externalCourseId: String
    let teeName: String
    let gender: String?
    let courseRating: Double?
    let slopeRating: Int?
    let bogeyRating: Double?
    let parTotal: Int?
    let totalYards: Int?
    let totalMeters: Int?
    let frontCourseRating: Double?
    let frontSlopeRating: Int?
    let backCourseRating: Double?
    let backSlopeRating: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case courseId = "course_id"
        case externalCourseId = "external_course_id"
        case teeName = "tee_name"
        case gender
        case courseRating = "course_rating"
        case slopeRating = "slope_rating"
        case bogeyRating = "bogey_rating"
        case parTotal = "par_total"
        case totalYards = "total_yards"
        case totalMeters = "total_meters"
        case frontCourseRating = "front_course_rating"
        case frontSlopeRating = "front_slope_rating"
        case backCourseRating = "back_course_rating"
        case backSlopeRating = "back_slope_rating"
    }
}

struct CachedCourseTeeHole: Identifiable, Hashable, Codable {
    let id: UUID
    let teeId: UUID
    let holeNumber: Int
    let par: Int?
    let yardage: Int?
    let handicap: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case teeId = "tee_id"
        case holeNumber = "hole_number"
        case par, yardage, handicap
    }
}

// MARK: - Service

/// Client-side wrapper around the `golfcourse-search` Edge Function plus the
/// `course_tees` / `course_tee_holes` Supabase tables.
///
/// Two operations:
///   - `search(query:)` — fan-out to GolfCourseAPI via the Edge Function.
///     Side effect: tee data for every returned course is cached server-side.
///   - `cachedTees(forExternalCourseId:)` — read the cached tee + per-hole
///     data for a specific course (after the user picks one).
///
/// Shared between iOS and watchOS — both targets call the same Edge Function
/// and read from the same DB tables.
final class GolfCourseAPIService {
    static let shared = GolfCourseAPIService()

    private let supabase = SupabaseManager.shared
    private init() {}

    // MARK: Search

    /// Search for courses by name. Returns the courses GolfCourseAPI knows
    /// about; cache writes happen server-side as a side effect.
    func search(query: String) async throws -> [GCAPICourse] {
        let body: [String: Any] = ["query": query]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let response = try await invokeFunction(name: "golfcourse-search", body: payload)
        let decoded = try JSONDecoder().decode(GCAPISearchResponse.self, from: response)
        return decoded.courses ?? []
    }

    /// Fetch a specific course by GolfCourseAPI id. Same side effect as search
    /// — caches the result server-side. Useful for "refresh this course's data".
    func fetchCourse(externalId: Int) async throws -> GCAPICourse? {
        let body: [String: Any] = ["courseId": externalId]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let response = try await invokeFunction(name: "golfcourse-search", body: payload)
        let decoded = try JSONDecoder().decode(GCAPISearchResponse.self, from: response)
        return decoded.courses?.first
    }

    // MARK: Cached tee reads

    /// Read all cached tees for a given external course id, sorted by gender
    /// then tee name. Used by the tee-picker UI after the user has picked a
    /// course.
    func cachedTees(forExternalCourseId externalId: String) async throws -> [CachedCourseTee] {
        try await supabase.from("course_tees")
            .select()
            .eq("external_course_id", value: externalId)
            .order("gender")
            .order("tee_name")
            .execute()
            .value
    }

    /// Read the per-hole data for one specific tee.
    func cachedHoles(forTeeId teeId: UUID) async throws -> [CachedCourseTeeHole] {
        try await supabase.from("course_tee_holes")
            .select()
            .eq("tee_id", value: teeId)
            .order("hole_number")
            .execute()
            .value
    }

    // MARK: Edge Function invocation

    /// SDK doesn't have a `.functions.invoke(name:)` shortcut on this version —
    /// hit the function via the underlying URL with the user's bearer token.
    private func invokeFunction(name: String, body: Data) async throws -> Data {
        let url = SupabaseManager.shared.projectURL.appendingPathComponent("functions/v1/\(name)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The user's session JWT — the Edge Function uses this to verify the
        // caller is signed in. SDK's session refresh is automatic.
        let session = try await supabase.auth.session
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GolfCourseAPIError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw GolfCourseAPIError.httpStatus(http.statusCode, detail)
        }
        return data
    }
}

enum GolfCourseAPIError: Error, LocalizedError {
    case badResponse
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Bad response from GolfCourseAPI Edge Function"
        case .httpStatus(let code, let detail): return "HTTP \(code): \(detail.prefix(120))"
        }
    }
}
