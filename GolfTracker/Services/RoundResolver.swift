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

    /// A golf course candidate. Backed by an OSM `leisure=golf_course` feature
    /// (preferred) or a MapKit POI (fallback when OSM has nothing). Carries a
    /// polygon when OSM-sourced, used for the second-pass geometry query.
    struct POICandidate: Hashable {
        let name: String
        let coordinate: CLLocationCoordinate2D
        let distanceMeters: Double
        /// If non-nil, this candidate matched an existing Course in the user's
        /// DB and we should reuse that course id instead of creating a new one.
        let existingCourseId: UUID?
        /// OSM source data when available — drives the second-pass geometry
        /// query. nil when this candidate came from the MapKit fallback.
        let osmCandidate: OSMCourseCandidate?

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
        // First pass: ask OSM for nearby named golf courses. Each result has a
        // bounding polygon for the second-pass geometry query.
        osm.fetchCandidates(near: currentLocation) { [weak self] result in
            guard let self = self else { completion(nil); return }

            switch result {
            case .failure(let err):
                dprint("[RoundResolver] OSM candidate fetch failed (\(err)) — falling back to MapKit")
                self.searchMapKitPOIs(near: currentLocation) { mapkitPOIs in
                    self.continueAfterCandidates(mapkitPOIs, progress: progress, coursePicker: coursePicker, completion: completion)
                }
            case .success(let osmCandidates):
                if osmCandidates.isEmpty {
                    // OSM coverage gap. Use MapKit as the safety net.
                    dprint("[RoundResolver] OSM had no candidates — falling back to MapKit")
                    self.searchMapKitPOIs(near: currentLocation) { mapkitPOIs in
                        self.continueAfterCandidates(mapkitPOIs, progress: progress, coursePicker: coursePicker, completion: completion)
                    }
                } else {
                    let userLoc = CLLocation(latitude: currentLocation.latitude, longitude: currentLocation.longitude)
                    let pois = osmCandidates.map { c -> POICandidate in
                        let cLoc = CLLocation(latitude: c.centroid.latitude, longitude: c.centroid.longitude)
                        return POICandidate(
                            name: c.name,
                            coordinate: c.centroid.coordinate,
                            distanceMeters: cLoc.distance(from: userLoc),
                            existingCourseId: nil,
                            osmCandidate: c
                        )
                    }
                    self.continueAfterCandidates(pois, progress: progress, coursePicker: coursePicker, completion: completion)
                }
            }
        }
    }

    private func continueAfterCandidates(_ pois: [POICandidate],
                                         progress: @escaping (Step) -> Void,
                                         coursePicker: @escaping ([POICandidate], @escaping (POICandidate?) -> Void) -> Void,
                                         completion: @escaping (Resolution?) -> Void) {
        guard !pois.isEmpty else {
            progress(.failed("No golf course found nearby"))
            completion(nil)
            return
        }
        progress(.checkingDB)
        matchExistingCourses(for: pois) { [weak self] matched in
            guard let self = self else { completion(nil); return }
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

        // OSM-sourced candidates do the second-pass polygon-scoped geometry
        // query. MapKit fallback candidates skip OSM geometry entirely (we
        // have no polygon to scope to) and the round starts as Tier `none`.
        guard let osmCandidate = candidate.osmCandidate else {
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
            return
        }
        osm.fetchCourseGeometry(for: osmCandidate) { result in
            let osmData: OSMCourseData?
            let tier: OSMCourseData.Tier
            switch result {
            case .success(let d):
                osmData = d
                tier = d.tier
            case .failure(let err):
                dprint("[RoundResolver] OSM geometry fetch failed: \(err) — round starts with no OSM data")
                osmData = nil
                tier = .none
            }
            let resolution = Resolution(
                courseId: candidate.existingCourseId ?? UUID(),
                courseName: candidate.name,
                courseCoordinate: candidate.coordinate,
                osmData: osmData,
                tier: tier,
                isExistingCourse: candidate.existingCourseId != nil
            )
            progress(.ready(resolution))
            completion(resolution)
        }
    }

    // MARK: - MapKit fallback POI search (used only when OSM is empty)

    private func searchMapKitPOIs(near coordinate: CLLocationCoordinate2D,
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
                    existingCourseId: nil,
                    osmCandidate: nil
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
                        existingCourseId: existing?.id,
                        osmCandidate: poi.osmCandidate
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
