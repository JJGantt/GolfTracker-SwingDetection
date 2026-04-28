import Foundation
import CoreLocation
import MapKit
import Supabase

/// Orchestrates the "start a round from here" flow for either device:
///
/// 1. **Existing-course-first**: query the user's saved courses for any
///    within ~500m of GPS. If exactly one match, prompt "Play <name>?" — if
///    yes, start the round on that course immediately (cached OSM data, no
///    Overpass query). If "different course", fall through to step 2.
/// 2. Use OSM Overpass to fetch nearby `leisure=golf_course` candidates
///    (MapKit fallback if OSM has nothing).
/// 3. Pick a course (auto when isolated, picker when ambiguous).
/// 4. Resolve OSM geometry for the chosen course (cache hit fast path).
/// 5. Return the round-ready Resolution with tier classification.
///
/// Both the iPhone and the Apple Watch can drive this flow — it has no
/// platform-specific dependencies beyond MapKit/CoreLocation/SDK, all of which
/// are available on both.
final class RoundResolver {
    static let shared = RoundResolver()

    private let supabase = SupabaseManager.shared
    private let osm = OSMCourseService.shared

    /// How close (meters) a saved course's centroid needs to be for the
    /// existing-course-first prompt to fire.
    var existingCourseProximityMeters: Double = 500

    private init() {}

    // MARK: - Types

    /// Streamed status for a status string in the UI ("Locating course...", etc).
    enum Step {
        case locating
        case checkingExisting
        /// User must confirm whether to play an existing course found nearby
        /// (or pick "Different course" to fall through to OSM resolution).
        case confirmingExisting(ExistingCourseMatch)
        case searchingPOIs
        case checkingDB
        case picking([POICandidate])              // multiple options — user must choose
        case loadingCourseData(courseName: String)
        case ready(Resolution)
        case failed(String)
    }

    /// A saved-course match presented to the user as "Play <name>?"
    struct ExistingCourseMatch: Hashable {
        let courseId: UUID
        let courseName: String
        let centroid: CLLocationCoordinate2D
        let distanceMeters: Double

        static func == (lhs: ExistingCourseMatch, rhs: ExistingCourseMatch) -> Bool {
            lhs.courseId == rhs.courseId
        }
        func hash(into hasher: inout Hasher) { hasher.combine(courseId) }
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
        existingCoursePrompt: @escaping (ExistingCourseMatch, @escaping (Bool) -> Void) -> Void = { _, cb in cb(false) },
        completion: @escaping (Resolution?) -> Void
    ) {
        // Step 1: existing-course-first proximity check. If we find exactly
        // one saved course nearby, prompt the user to confirm before doing
        // any OSM work.
        progress(.checkingExisting)
        findExistingCourseMatches(near: currentLocation) { [weak self] matches in
            guard let self = self else { completion(nil); return }
            if matches.count == 1, let match = matches.first {
                progress(.confirmingExisting(match))
                existingCoursePrompt(match) { confirmed in
                    if confirmed {
                        self.resolveExisting(match, progress: progress, completion: completion)
                    } else {
                        // User said "different course" — fall through to OSM.
                        self.resolveViaOSM(at: currentLocation, progress: progress, coursePicker: coursePicker, completion: completion)
                    }
                }
            } else {
                // 0 matches → straight to OSM. >1 matches → also OSM (let
                // the regular picker handle disambiguation; no good UX for
                // "you have 3 courses near here, which one?" without one).
                self.resolveViaOSM(at: currentLocation, progress: progress, coursePicker: coursePicker, completion: completion)
            }
        }
    }

    /// Fast path — saved course within proximity. Skip OSM entirely; reuse
    /// whatever cached geometry the existing course has.
    private func resolveExisting(_ match: ExistingCourseMatch,
                                 progress: @escaping (Step) -> Void,
                                 completion: @escaping (Resolution?) -> Void) {
        progress(.loadingCourseData(courseName: match.courseName))
        // Pull cached OSM data for the course (if any). If not cached, the
        // round still starts; the picker UX falls back to manual hole entry.
        osm.fetchFromCache(near: match.centroid) { osmData in
            let tier = osmData?.tier ?? .none
            let resolution = Resolution(
                courseId: match.courseId,
                courseName: match.courseName,
                courseCoordinate: match.centroid,
                osmData: osmData,
                tier: tier,
                isExistingCourse: true
            )
            progress(.ready(resolution))
            completion(resolution)
        }
    }

    /// Row shape for the proximity check — we need each course's hole coords
    /// to compute a centroid for distance comparison.
    private struct CourseProximityRow: Decodable {
        let id: UUID
        let name: String
        let holes: [HoleCoord]
        struct HoleCoord: Decodable {
            let latitude: Double?
            let longitude: Double?
        }
    }

    /// Pull every saved course for the user, compute each one's centroid
    /// from its holes, and return the ones within `existingCourseProximityMeters`.
    private func findExistingCourseMatches(near coordinate: CLLocationCoordinate2D,
                                           completion: @escaping ([ExistingCourseMatch]) -> Void) {
        Task {
            do {
                let rows: [CourseProximityRow] = try await supabase.from("courses")
                    .select("id,name,holes(latitude,longitude)")
                    .execute()
                    .value
                let userLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                let matches: [ExistingCourseMatch] = rows.compactMap { row in
                    let coords = row.holes.compactMap { hc -> CLLocationCoordinate2D? in
                        guard let lat = hc.latitude, let lon = hc.longitude else { return nil }
                        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    }
                    guard !coords.isEmpty else { return nil }
                    let centLat = coords.map(\.latitude).reduce(0, +) / Double(coords.count)
                    let centLon = coords.map(\.longitude).reduce(0, +) / Double(coords.count)
                    let centroid = CLLocationCoordinate2D(latitude: centLat, longitude: centLon)
                    let dist = CLLocation(latitude: centLat, longitude: centLon).distance(from: userLoc)
                    guard dist <= self.existingCourseProximityMeters else { return nil }
                    return ExistingCourseMatch(
                        courseId: row.id,
                        courseName: row.name,
                        centroid: centroid,
                        distanceMeters: dist
                    )
                }
                completion(matches.sorted { $0.distanceMeters < $1.distanceMeters })
            } catch {
                dprint("[RoundResolver] existing-course proximity check failed: \(error)")
                completion([])
            }
        }
    }

    private func resolveViaOSM(
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
