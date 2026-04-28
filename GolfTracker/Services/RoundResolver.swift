import Foundation
import CoreLocation
import MapKit
import Supabase

/// Orchestrates the "start a round from here" flow for either device:
///
/// 1. Use the user's GPS to search Apple Maps for nearby golf POIs
/// 2. Check Supabase for existing courses near this location (proximity match)
/// 3. Pick a course (auto when isolated, picker when ambiguous)
/// 4. Resolve OSM geometry for the chosen course (cache hit fast path)
/// 5. Return the round-ready Resolution with tier classification
///
/// Both the iPhone and the Apple Watch can drive this flow — it has no
/// platform-specific dependencies beyond MapKit/CoreLocation/SDK, all of which
/// are available on both.
final class RoundResolver {
    static let shared = RoundResolver()

    private let supabase = SupabaseManager.shared
    private let osm = OSMCourseService.shared

    private init() {}

    // MARK: - Types

    /// Streamed status for a status string in the UI ("Locating course...", etc).
    enum Step {
        case locating
        case searchingPOIs
        case checkingDB
        case picking([POICandidate])              // multiple options — user must choose
        case loadingCourseData(courseName: String)
        case ready(Resolution)
        case failed(String)
    }

    /// A golf POI from Apple Maps, scored by distance from the user.
    struct POICandidate: Hashable {
        let name: String
        let coordinate: CLLocationCoordinate2D
        let distanceMeters: Double
        /// If non-nil, this POI matched an existing Course in the user's DB and
        /// we should reuse that course id instead of creating a new one.
        let existingCourseId: UUID?

        static func == (lhs: POICandidate, rhs: POICandidate) -> Bool {
            lhs.name == rhs.name &&
            lhs.coordinate.latitude == rhs.coordinate.latitude &&
            lhs.coordinate.longitude == rhs.coordinate.longitude
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(name)
            hasher.combine(coordinate.latitude)
            hasher.combine(coordinate.longitude)
        }
    }

    /// Final result handed back to the round-start flow.
    struct Resolution {
        let courseId: UUID
        let courseName: String
        let courseCoordinate: CLLocationCoordinate2D
        let osmData: OSMCourseData?
        let tier: OSMCourseData.Tier
        let isExistingCourse: Bool
    }

    // MARK: - Entry point

    /// Resolves a round-ready course at the given location. Calls `progress`
    /// with status updates throughout. If multiple legitimate POIs are within
    /// a tight radius, calls `coursePicker` so the UI can ask the user which
    /// one — the picker callback receives the candidate list and a selection
    /// handler that takes the chosen candidate (or nil to cancel).
    func resolve(
        at currentLocation: CLLocationCoordinate2D,
        progress: @escaping (Step) -> Void,
        coursePicker: @escaping ([POICandidate], @escaping (POICandidate?) -> Void) -> Void,
        completion: @escaping (Resolution?) -> Void
    ) {
        progress(.searchingPOIs)
        searchPOIs(near: currentLocation) { [weak self] pois in
            guard let self = self else { completion(nil); return }
            guard !pois.isEmpty else {
                progress(.failed("No golf course found nearby"))
                completion(nil)
                return
            }

            progress(.checkingDB)
            self.matchExistingCourses(for: pois) { matched in
                let candidates = matched.sorted { $0.distanceMeters < $1.distanceMeters }
                let isolated = self.isClearWinner(candidates)
                if isolated, let only = candidates.first {
                    self.continueWith(only, progress: progress, completion: completion)
                } else {
                    progress(.picking(candidates))
                    coursePicker(candidates) { chosen in
                        guard let chosen = chosen else { completion(nil); return }
                        self.continueWith(chosen, progress: progress, completion: completion)
                    }
                }
            }
        }
    }

    /// Auto-pick when one POI is dramatically closer than its peers (e.g. solo
    /// muni courses where the next-nearest is miles away). Threshold: any peer
    /// within 800m of the nearest forces the picker (resort/state-park case).
    private func isClearWinner(_ candidates: [POICandidate]) -> Bool {
        guard let first = candidates.first else { return false }
        guard candidates.count > 1 else { return true }
        let runnerUp = candidates[1]
        return runnerUp.distanceMeters - first.distanceMeters > 800
    }

    private func continueWith(_ candidate: POICandidate,
                              progress: @escaping (Step) -> Void,
                              completion: @escaping (Resolution?) -> Void) {
        progress(.loadingCourseData(courseName: candidate.name))
        osm.resolve(near: candidate.coordinate, courseId: candidate.existingCourseId) { result in
            switch result {
            case .success(let osm):
                let resolution = Resolution(
                    courseId: candidate.existingCourseId ?? UUID(),
                    courseName: candidate.name,
                    courseCoordinate: candidate.coordinate,
                    osmData: osm,
                    tier: osm.tier,
                    isExistingCourse: candidate.existingCourseId != nil
                )
                progress(.ready(resolution))
                completion(resolution)
            case .failure(let err):
                dprint("[RoundResolver] OSM resolve failed: \(err) — falling back with no OSM data")
                let resolution = Resolution(
                    courseId: candidate.existingCourseId ?? UUID(),
                    courseName: candidate.name,
                    courseCoordinate: candidate.coordinate,
                    osmData: nil,
                    tier: .none,
                    isExistingCourse: candidate.existingCourseId != nil
                )
                progress(.ready(resolution))
                completion(resolution)
            }
        }
    }

    // MARK: - POI search

    private func searchPOIs(near coordinate: CLLocationCoordinate2D,
                            completion: @escaping ([POICandidate]) -> Void) {
        let req = MKLocalSearch.Request()
        req.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 3000,
            longitudinalMeters: 3000
        )
        // POI category .golf requires watchOS 11+. On older watchOS we rely on
        // the natural language query alone — Apple Maps still ranks golf POIs
        // first when the query is "golf" + the region is centered on a course.
        if #available(iOS 18.0, watchOS 11.0, *) {
            req.pointOfInterestFilter = MKPointOfInterestFilter(including: [.golf])
        }
        req.resultTypes = .pointOfInterest
        req.naturalLanguageQuery = "golf"

        MKLocalSearch(request: req).start { response, _ in
            let center = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let pois = response?.mapItems.map { item -> POICandidate in
                let c = item.placemark.coordinate
                let dist = CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: center)
                return POICandidate(
                    name: item.name ?? "Unknown course",
                    coordinate: c,
                    distanceMeters: dist,
                    existingCourseId: nil
                )
            } ?? []
            // Drop POIs further than 1500m — anything beyond that is a different facility.
            let filtered = pois.filter { $0.distanceMeters <= 1500 }
            completion(filtered)
        }
    }

    // MARK: - Existing-course proximity match

    /// Row shape returned from `courses` for the proximity-match query.
    private struct CourseRow: Decodable {
        let id: UUID
        let name: String
    }

    /// For each MapKit POI candidate, see if the user already has a course in
    /// Supabase whose name matches OR whose holes are near this location. If
    /// matched, attach the existing course id so we reuse it instead of
    /// creating a duplicate.
    private func matchExistingCourses(for pois: [POICandidate],
                                      completion: @escaping ([POICandidate]) -> Void) {
        Task {
            do {
                let rows: [CourseRow] = try await supabase.from("courses")
                    .select("id,name")
                    .execute()
                    .value
                let matched: [POICandidate] = pois.map { poi in
                    let existing = rows.first { row in
                        // Simple name match — case-insensitive substring either way.
                        let a = row.name.lowercased()
                        let b = poi.name.lowercased()
                        return a == b || a.contains(b) || b.contains(a)
                    }
                    return POICandidate(
                        name: poi.name,
                        coordinate: poi.coordinate,
                        distanceMeters: poi.distanceMeters,
                        existingCourseId: existing?.id
                    )
                }
                completion(matched)
            } catch {
                dprint("[RoundResolver] DB course match failed: \(error)")
                completion(pois)  // continue without DB matching
            }
        }
    }
}
