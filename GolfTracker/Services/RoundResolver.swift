import Foundation
import CoreLocation
import MapKit
import Supabase

/// Orchestrates the "start a round from here" flow on either device.
///
/// **Single-flow design** (post-migration 00026 — shared courses):
///
///   1. Query the shared `courses` table for any rows whose `center_lat/lon`
///      is within `nearbyRadiusMeters` (~3 miles) of the user's GPS. This is
///      THE primary resolution path — every course any user has played is in
///      this table, so a "new" course only appears the first time anyone
///      registers it.
///   2. If the proximity query returns rows: present a picker (auto-pick if
///      exactly one). On pick, build a Resolution from the row's cached
///      `osm_polygons` blob + cached `external_course_id` (no Overpass call,
///      no GolfCourseAPI call).
///   3. If the proximity query returns nothing: fall through to OSM Overpass.
///      User picks. We fetch geometry, search GolfCourseAPI for scorecard
///      data, then INSERT one row into the shared `courses` table carrying
///      everything (`center_lat`, `center_lon`, `osm_id`, `external_course_id`,
///      `osm_polygons`) plus the per-hole rows. The next user at the same
///      course hits step 1 instead.
///
/// MapKit is the last-resort fallback when OSM has zero matches — it has no
/// polygon data, so the round starts as Tier `none` and we don't INSERT a
/// shared row (we'd be persisting incomplete data).
final class RoundResolver {
    static let shared = RoundResolver()

    private let supabase = SupabaseManager.shared
    private let osm = OSMCourseService.shared

    /// Search radius for the shared-courses proximity query. 3 miles covers
    /// resort-style multi-course campuses (Pinehurst, Bandon, Bethpage)
    /// without false-positive hits at courses across town.
    var nearbyRadiusMeters: Double = 4800

    private init() {}

    // MARK: - Types

    /// Streamed status string for the UI ("Locating…", etc).
    enum Step {
        case locating
        case searchingShared
        case searchingPOIs
        case picking([CourseCandidate])
        case loadingCourseData(courseName: String)
        case ready(Resolution)
        case failed(String)
    }

    /// A course the user can pick. May be backed by a row already in the
    /// shared courses table, an OSM feature we'd register on confirmation, or
    /// a MapKit POI fallback.
    struct CourseCandidate: Hashable {
        let name: String
        let coordinate: CLLocationCoordinate2D
        let distanceMeters: Double
        let source: Source

        enum Source: Hashable {
            /// Already in the shared courses table. Has cached polygon data
            /// (when present) and external_course_id (when present).
            case shared(courseId: UUID, externalCourseId: String?, osmId: Int64?)
            /// Found via OSM. INSERT-on-pick.
            case osm(OSMCourseCandidate)
            /// MapKit fallback (OSM coverage gap). No polygon data, no INSERT
            /// to shared courses.
            case mapKit
        }

        static func == (lhs: CourseCandidate, rhs: CourseCandidate) -> Bool {
            switch (lhs.source, rhs.source) {
            case (.shared(let a, _, _), .shared(let b, _, _)):
                return a == b
            default:
                return lhs.name == rhs.name &&
                       lhs.coordinate.latitude == rhs.coordinate.latitude &&
                       lhs.coordinate.longitude == rhs.coordinate.longitude
            }
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
        /// True iff the course was already in the shared courses table when
        /// this resolution started. Drives whether the caller skips the
        /// course-row INSERT (it's already there).
        let isExistingCourse: Bool
        /// GolfCourseAPI scorecard. nil for courses the API doesn't have.
        let scorecardCourse: GCAPICourse?
    }

    // MARK: - Entry point

    /// Resolve a round-ready course at `currentLocation`. Streams status via
    /// `progress`. When more than one candidate is plausible, calls
    /// `coursePicker` so the UI can ask the user which one (or nil to cancel).
    func resolve(
        at currentLocation: CLLocationCoordinate2D,
        progress: @escaping (Step) -> Void,
        coursePicker: @escaping ([CourseCandidate], @escaping (CourseCandidate?) -> Void) -> Void,
        completion: @escaping (Resolution?) -> Void
    ) {
        progress(.searchingShared)
        Task {
            let shared = (try? await fetchSharedCoursesNear(currentLocation)) ?? []
            ClientEventLogger.log("resolver.sharedQuery", detail: [
                "matchCount": .integer(shared.count)
            ])
            if !shared.isEmpty {
                self.presentCandidates(shared, progress: progress, coursePicker: coursePicker, completion: completion)
                return
            }
            // No shared course nearby — fall through to OSM.
            self.resolveViaOSM(at: currentLocation, progress: progress, coursePicker: coursePicker, completion: completion)
        }
    }

    // MARK: - Shared-courses proximity

    private struct SharedCourseRow: Decodable {
        let id: UUID
        let name: String
        let center_lat: Double?
        let center_lon: Double?
        let osm_id: Int64?
        let external_course_id: String?
        /// Encoded as JSONB on the server; decoded into OSMCourseData below.
        let osm_polygons: OSMCourseData?
    }

    private func fetchSharedCoursesNear(_ coordinate: CLLocationCoordinate2D) async throws -> [CourseCandidate] {
        // Coarse bounding box. lat: 1° ≈ 111km. lon scales by cos(lat).
        let latDelta = nearbyRadiusMeters / 111_000.0
        let lonDelta = nearbyRadiusMeters / (111_000.0 * max(cos(coordinate.latitude * .pi / 180), 0.01))
        let minLat = coordinate.latitude - latDelta
        let maxLat = coordinate.latitude + latDelta
        let minLon = coordinate.longitude - lonDelta
        let maxLon = coordinate.longitude + lonDelta

        let rows: [SharedCourseRow] = try await supabase.from("courses")
            .select("id,name,center_lat,center_lon,osm_id,external_course_id,osm_polygons")
            .gte("center_lat", value: minLat)
            .lte("center_lat", value: maxLat)
            .gte("center_lon", value: minLon)
            .lte("center_lon", value: maxLon)
            .execute()
            .value

        let userLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let candidates: [CourseCandidate] = rows.compactMap { row in
            guard let lat = row.center_lat, let lon = row.center_lon else { return nil }
            let dist = CLLocation(latitude: lat, longitude: lon).distance(from: userLoc)
            guard dist <= nearbyRadiusMeters else { return nil }
            return CourseCandidate(
                name: row.name,
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                distanceMeters: dist,
                source: .shared(
                    courseId: row.id,
                    externalCourseId: row.external_course_id,
                    osmId: row.osm_id
                )
            )
        }
        return candidates.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    // MARK: - OSM fallback (miss path)

    private func resolveViaOSM(
        at currentLocation: CLLocationCoordinate2D,
        progress: @escaping (Step) -> Void,
        coursePicker: @escaping ([CourseCandidate], @escaping (CourseCandidate?) -> Void) -> Void,
        completion: @escaping (Resolution?) -> Void
    ) {
        progress(.searchingPOIs)
        osm.fetchCandidates(near: currentLocation) { [weak self] result in
            guard let self = self else { completion(nil); return }
            switch result {
            case .success(let osmCandidates) where !osmCandidates.isEmpty:
                let userLoc = CLLocation(latitude: currentLocation.latitude, longitude: currentLocation.longitude)
                let candidates = osmCandidates.map { c -> CourseCandidate in
                    let cLoc = CLLocation(latitude: c.centroid.latitude, longitude: c.centroid.longitude)
                    return CourseCandidate(
                        name: c.name,
                        coordinate: c.centroid.coordinate,
                        distanceMeters: cLoc.distance(from: userLoc),
                        source: .osm(c)
                    )
                }
                .sorted { $0.distanceMeters < $1.distanceMeters }
                self.presentCandidates(candidates, progress: progress, coursePicker: coursePicker, completion: completion)
            default:
                // OSM empty or errored — last-resort MapKit.
                self.searchMapKitPOIs(near: currentLocation) { mapkit in
                    if mapkit.isEmpty {
                        progress(.failed("No golf course found nearby"))
                        completion(nil)
                    } else {
                        self.presentCandidates(mapkit, progress: progress, coursePicker: coursePicker, completion: completion)
                    }
                }
            }
        }
    }

    private func presentCandidates(_ candidates: [CourseCandidate],
                                   progress: @escaping (Step) -> Void,
                                   coursePicker: @escaping ([CourseCandidate], @escaping (CourseCandidate?) -> Void) -> Void,
                                   completion: @escaping (Resolution?) -> Void) {
        guard !candidates.isEmpty else {
            progress(.failed("No golf course found nearby"))
            completion(nil)
            return
        }
        if candidates.count == 1, let only = candidates.first {
            self.continueWith(only, progress: progress, completion: completion)
            return
        }
        progress(.picking(candidates))
        coursePicker(candidates) { [weak self] chosen in
            guard let self = self, let chosen = chosen else { completion(nil); return }
            self.continueWith(chosen, progress: progress, completion: completion)
        }
    }

    // MARK: - Build resolution from a picked candidate

    private func continueWith(_ candidate: CourseCandidate,
                              progress: @escaping (Step) -> Void,
                              completion: @escaping (Resolution?) -> Void) {
        progress(.loadingCourseData(courseName: candidate.name))

        switch candidate.source {
        case .shared(let courseId, let externalId, let osmId):
            resolveExistingShared(
                courseId: courseId,
                courseName: candidate.name,
                coordinate: candidate.coordinate,
                externalCourseId: externalId,
                osmId: osmId,
                progress: progress,
                completion: completion
            )
        case .osm(let osmCandidate):
            resolveAndRegisterOSM(
                osmCandidate: osmCandidate,
                userPickedName: candidate.name,
                userPickedCoord: candidate.coordinate,
                progress: progress,
                completion: completion
            )
        case .mapKit:
            // No polygon data, no scorecard search proximity. Start a Tier-none
            // round and don't write to shared courses (we'd be persisting an
            // incomplete record).
            resolveScorecard(courseName: candidate.name, near: candidate.coordinate, knownExternalCourseId: nil) { scorecard in
                let resolution = Resolution(
                    courseId: UUID(),
                    courseName: candidate.name,
                    courseCoordinate: candidate.coordinate,
                    osmData: nil,
                    tier: .none,
                    isExistingCourse: false,
                    scorecardCourse: scorecard
                )
                progress(.ready(resolution))
                completion(resolution)
            }
        }
    }

    /// Existing shared course pick. Pull cached osm_polygons, optionally
    /// pull cached scorecard via cached external_course_id. No Overpass, no
    /// Edge Function call when both caches are populated.
    private func resolveExistingShared(courseId: UUID,
                                       courseName: String,
                                       coordinate: CLLocationCoordinate2D,
                                       externalCourseId: String?,
                                       osmId: Int64?,
                                       progress: @escaping (Step) -> Void,
                                       completion: @escaping (Resolution?) -> Void) {
        Task {
            // Re-fetch the row to get fresh osm_polygons (we already have it
            // from the proximity query, but a single targeted fetch keeps
            // this code path simple — and the row is small).
            let osmData: OSMCourseData? = await {
                do {
                    let rows: [SharedCourseRow] = try await self.supabase.from("courses")
                        .select("id,name,center_lat,center_lon,osm_id,external_course_id,osm_polygons")
                        .eq("id", value: courseId.uuidString)
                        .limit(1)
                        .execute()
                        .value
                    return rows.first?.osm_polygons
                } catch {
                    dprint("[RoundResolver] re-fetch shared course failed: \(error)")
                    return nil
                }
            }()
            _ = osmId  // currently unused; kept on the candidate for future polygon-refresh logic.

            self.resolveScorecard(courseName: courseName, near: coordinate, knownExternalCourseId: externalCourseId) { scorecard in
                let resolution = Resolution(
                    courseId: courseId,
                    courseName: courseName,
                    courseCoordinate: coordinate,
                    osmData: osmData,
                    tier: osmData?.tier ?? .none,
                    isExistingCourse: true,
                    scorecardCourse: scorecard
                )
                progress(.ready(resolution))
                completion(resolution)
            }
        }
    }

    /// OSM-discovered course not yet in shared courses. Fetch geometry, find
    /// scorecard, then INSERT one shared courses row + its hole rows.
    private func resolveAndRegisterOSM(osmCandidate: OSMCourseCandidate,
                                       userPickedName: String,
                                       userPickedCoord: CLLocationCoordinate2D,
                                       progress: @escaping (Step) -> Void,
                                       completion: @escaping (Resolution?) -> Void) {
        osm.fetchCourseGeometry(for: osmCandidate) { [weak self] result in
            guard let self = self else { completion(nil); return }
            let osmData: OSMCourseData?
            let tier: OSMCourseData.Tier
            switch result {
            case .success(let d): osmData = d; tier = d.tier
            case .failure(let e):
                dprint("[RoundResolver] OSM geometry fetch failed: \(e)")
                osmData = nil; tier = .none
            }
            self.resolveScorecard(courseName: userPickedName, near: userPickedCoord, knownExternalCourseId: nil) { scorecard in
                // Compute centroid: prefer OSM-derived holes, fall back to
                // the candidate's polygon centroid.
                let centroid: CLLocationCoordinate2D = {
                    if let osm = osmData, !osm.holes.isEmpty {
                        let lats = osm.holes.map { $0.greenPoint.latitude }
                        let lons = osm.holes.map { $0.greenPoint.longitude }
                        return CLLocationCoordinate2D(
                            latitude: lats.reduce(0, +) / Double(lats.count),
                            longitude: lons.reduce(0, +) / Double(lons.count)
                        )
                    }
                    return osmCandidate.centroid.coordinate
                }()
                let newCourseId = UUID()
                self.insertSharedCourse(
                    id: newCourseId,
                    name: userPickedName,
                    centroid: centroid,
                    osmId: osmCandidate.osmId,
                    externalCourseId: scorecard.map { String($0.id) },
                    osmData: osmData
                )
                let resolution = Resolution(
                    courseId: newCourseId,
                    courseName: userPickedName,
                    courseCoordinate: centroid,
                    osmData: osmData,
                    tier: tier,
                    isExistingCourse: false,
                    scorecardCourse: scorecard
                )
                progress(.ready(resolution))
                completion(resolution)
            }
        }
    }

    /// One-shot INSERT of a shared courses row carrying everything resolved
    /// for this physical course. Idempotent on `osm_id` (unique index from
    /// migration 00026), so two users registering the same course at the same
    /// time collapse to one row.
    private func insertSharedCourse(id: UUID,
                                    name: String,
                                    centroid: CLLocationCoordinate2D,
                                    osmId: Int64,
                                    externalCourseId: String?,
                                    osmData: OSMCourseData?) {
        struct Row: Encodable {
            let id: String
            let name: String
            let center_lat: Double
            let center_lon: Double
            let osm_id: Int64
            let external_course_id: String?
            let osm_polygons: OSMCourseData?
        }
        let row = Row(
            id: id.uuidString,
            name: name,
            center_lat: centroid.latitude,
            center_lon: centroid.longitude,
            osm_id: osmId,
            external_course_id: externalCourseId,
            osm_polygons: osmData
        )
        Task {
            do {
                try await supabase.from("courses")
                    .upsert(row, onConflict: "osm_id")
                    .execute()
                ClientEventLogger.log("resolver.sharedCourseInserted", detail: [
                    "courseId": .string(id.uuidString),
                    "osmId": .integer(Int(osmId)),
                    "externalCourseId": externalCourseId.map(AnyJSON.string) ?? .null
                ])
                if let osmData = osmData {
                    await self.insertHolesIfMissing(courseId: id, osmData: osmData)
                }
            } catch {
                ClientEventLogger.log("resolver.sharedCourseInsertFailed", detail: [
                    "error": .string("\(error)")
                ])
            }
        }
    }

    /// Insert per-hole rows into the shared `holes` table, but only when none
    /// exist yet for this course — avoids duplicating rows on re-resolution
    /// (osm_id uniqueness collapses the parent INSERT, but holes have no
    /// natural cross-resolution key, so we gate on emptiness instead).
    /// Skips holes whose `ref` doesn't parse cleanly — Tier `partial`
    /// courses (Bethpage umbrellas, Pinehurst overlaps) yield zero rows
    /// rather than messy half-mapped data.
    private func insertHolesIfMissing(courseId: UUID, osmData: OSMCourseData) async {
        struct ExistingRow: Decodable { let id: UUID }
        struct HoleRow: Encodable {
            let id: String
            let course_id: String
            let number: Int
            let latitude: Double
            let longitude: Double
            let par: Int?
        }
        do {
            let existing: [ExistingRow] = try await supabase.from("holes")
                .select("id")
                .eq("course_id", value: courseId.uuidString)
                .limit(1)
                .execute()
                .value
            if !existing.isEmpty { return }

            let rows: [HoleRow] = osmData.holes.compactMap { h in
                guard let ref = h.ref, let n = Int(ref) else { return nil }
                return HoleRow(
                    id: UUID().uuidString,
                    course_id: courseId.uuidString,
                    number: n,
                    latitude: h.greenPoint.latitude,
                    longitude: h.greenPoint.longitude,
                    par: h.par
                )
            }
            guard !rows.isEmpty else { return }
            try await supabase.from("holes").insert(rows).execute()
            ClientEventLogger.log("resolver.sharedHolesInserted", detail: [
                "courseId": .string(courseId.uuidString),
                "count": .integer(rows.count)
            ])
        } catch {
            ClientEventLogger.log("resolver.sharedHolesInsertFailed", detail: [
                "error": .string("\(error)")
            ])
        }
    }

    // MARK: - Scorecard (GolfCourseAPI)

    /// Returns scorecard data (tee list, per-hole pars/yards). Fast path uses
    /// the cached `course_tees` rows when we already know external_course_id.
    private func resolveScorecard(courseName: String,
                                  near coordinate: CLLocationCoordinate2D,
                                  knownExternalCourseId: String?,
                                  completion: @escaping (GCAPICourse?) -> Void) {
        if let externalId = knownExternalCourseId {
            Task {
                do {
                    let cached = try await GolfCourseAPIService.shared.cachedTees(forExternalCourseId: externalId)
                    if let stub = Self.makeStubCourse(externalId: externalId, name: courseName, coord: coordinate, cachedTees: cached) {
                        ClientEventLogger.log("resolver.scorecard.fastPathHit", detail: [
                            "externalCourseId": .string(externalId),
                            "teeCount": .integer(cached.count)
                        ])
                        completion(stub)
                        return
                    }
                } catch {
                    dprint("[RoundResolver] cached tees fetch failed: \(error)")
                }
                // Cache miss — fall through to a search.
                await self.searchScorecard(courseName: courseName, near: coordinate, completion: completion)
            }
            return
        }
        Task { await searchScorecard(courseName: courseName, near: coordinate, completion: completion) }
    }

    private func searchScorecard(courseName: String,
                                 near coordinate: CLLocationCoordinate2D,
                                 completion: @escaping (GCAPICourse?) -> Void) async {
        do {
            let candidates = try await GolfCourseAPIService.shared.search(query: courseName)
            let userLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let best = candidates
                .compactMap { c -> (GCAPICourse, Double)? in
                    guard let coord = c.coordinate else { return nil }
                    let dist = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                        .distance(from: userLoc)
                    return (c, dist)
                }
                .filter { $0.1 <= 1500 }
                .min(by: { $0.1 < $1.1 })?.0
            ClientEventLogger.log(best == nil ? "resolver.scorecard.searchNoMatch" : "resolver.scorecard.searchMatched",
                                  detail: best.map { ["externalCourseId": .integer($0.id)] } ?? [:])
            completion(best)
        } catch {
            dprint("[RoundResolver] GolfCourseAPI search failed: \(error)")
            completion(nil)
        }
    }

    private static func makeStubCourse(externalId: String, name: String, coord: CLLocationCoordinate2D, cachedTees: [CachedCourseTee]) -> GCAPICourse? {
        guard !cachedTees.isEmpty, let intId = Int(externalId) else { return nil }
        let teeBoxes: [GCAPITeeBox] = cachedTees.map { t in
            GCAPITeeBox(
                tee_name: t.teeName,
                course_rating: t.courseRating,
                slope_rating: t.slopeRating,
                bogey_rating: t.bogeyRating,
                total_yards: t.totalYards,
                total_meters: t.totalMeters,
                number_of_holes: nil,
                par_total: t.parTotal,
                front_course_rating: t.frontCourseRating,
                front_slope_rating: t.frontSlopeRating,
                front_bogey_rating: nil,
                back_course_rating: t.backCourseRating,
                back_slope_rating: t.backSlopeRating,
                back_bogey_rating: nil,
                holes: nil
            )
        }
        let tees = GCAPITees(
            female: teeBoxes.filter { box in cachedTees.first(where: { $0.teeName == box.tee_name })?.gender == "female" },
            male: teeBoxes.filter { box in cachedTees.first(where: { $0.teeName == box.tee_name })?.gender == "male" }
        )
        return GCAPICourse(
            id: intId,
            club_name: name,
            course_name: name,
            location: GCAPILocation(address: nil, city: nil, state: nil, country: nil, latitude: coord.latitude, longitude: coord.longitude),
            tees: tees
        )
    }

    // MARK: - MapKit fallback (used only when OSM is empty)

    private func searchMapKitPOIs(near coordinate: CLLocationCoordinate2D,
                                  completion: @escaping ([CourseCandidate]) -> Void) {
        let req = MKLocalSearch.Request()
        req.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 3000,
            longitudinalMeters: 3000
        )
        if #available(iOS 18.0, watchOS 11.0, *) {
            req.pointOfInterestFilter = MKPointOfInterestFilter(including: [.golf])
        }
        req.resultTypes = .pointOfInterest
        req.naturalLanguageQuery = "golf"

        MKLocalSearch(request: req).start { response, _ in
            let center = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let pois = (response?.mapItems ?? []).map { item -> CourseCandidate in
                let c = item.placemark.coordinate
                let dist = CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: center)
                return CourseCandidate(
                    name: item.name ?? "Unknown course",
                    coordinate: c,
                    distanceMeters: dist,
                    source: .mapKit
                )
            }
            completion(pois.filter { $0.distanceMeters <= 1500 }
                          .sorted { $0.distanceMeters < $1.distanceMeters })
        }
    }
}
