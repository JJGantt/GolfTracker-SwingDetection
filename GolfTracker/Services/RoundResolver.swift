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

    /// "In proximity" threshold for the scorecard picker. Same number for
    /// real API coords and city/state-derived coords — the picker is the
    /// disambiguator and the stripped course name is already doing the
    /// discriminating work, so two courses within this radius sharing the
    /// same stripped name is rare and the user resolves it. 25km is wide
    /// enough to catch multi-course resorts where the API stamps every
    /// course at the club's HQ centroid (e.g. Citrus Hills FL — Brentwood
    /// Farms is 3.8km from the Terra Vista cluster but listed at the same
    /// API lat/lon as the other three courses) while still excluding
    /// wrong-state matches (Sweetwater FL vs Sweetwater TX, >1500km).
    static let scorecardProximityMeters: Double = 25_000

    /// Stashed picker callback for the in-flight resolve(). One resolve
    /// runs at a time on watchOS (gated by user interaction), so a single
    /// shared slot is fine. Cleared after use.
    private var activeScorecardPicker: ScorecardPicker?
    private var activeCourseNamePrompt: CourseNamePrompt?
    private var activeOriginalName: String?

    private init() {}

    /// Wrapper for the scorecard picker UI: original API course + the
    /// distance bucket we put it in for sorting purposes.
    struct ScorecardCandidate: Hashable {
        enum Bucket: Int, Comparable {
            /// Within `scorecardProximityMeters` of the OSM course coords —
            /// either via real API-supplied coords or via city/state
            /// geocoding when the API didn't ship coords. Same threshold
            /// for both paths.
            case inRange = 0
            /// API coords nil AND city/state couldn't be geocoded (or was
            /// "Unknown"). Could still be the right course — user decides.
            case noLocation = 1
            static func < (l: Bucket, r: Bucket) -> Bool { l.rawValue < r.rawValue }
        }
        let course: GCAPICourse
        let bucket: Bucket
        /// Distance in meters from OSM course coords. Nil for `noLocation`.
        let distanceMeters: Double?
    }

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
            /// User is somewhere we can't identify — nothing nearby in the
            /// shared table, OSM, or MapKit. No OSM data and no scorecard;
            /// blob detection is the only source of hole geometry.
            ///
            /// The user NAMES it (see `courseNamePrompt`) and it is INSERTed
            /// into shared courses anchored at their current GPS, so the next
            /// round at the same place finds it by proximity under that name.
            /// It used to create a throwaway "Unlisted course" instead, which
            /// meant every visit made another anonymous entry and the Stats
            /// screen listed them as if they were venues.
            ///
            /// Always appended last in the picker, for when none of the
            /// surfaced courses is where the user actually is.
            case manual
        }

        static func == (lhs: CourseCandidate, rhs: CourseCandidate) -> Bool {
            switch (lhs.source, rhs.source) {
            case (.shared(let a, _, _), .shared(let b, _, _)):
                return a == b
            case (.manual, .manual):
                return true
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
    /// Picker callback signature for the scorecard step. The resolver
    /// hands the UI a ranked list of GCAPI candidates (by bucket: in-range,
    /// no-coords, out-of-range) plus the original OSM course name. UI
    /// displays them, lets the user pick one OR pick "course not listed"
    /// to skip the scorecard entirely. Nil completion = "not listed."
    typealias ScorecardPicker = (_ originalName: String,
                                 _ candidates: [ScorecardCandidate],
                                 _ choose: @escaping (GCAPICourse?) -> Void) -> Void

    /// Ask the user to name the place they're playing. Called only on the
    /// `.manual` path, where nothing identified the course. Completing with
    /// nil cancels the round — a name is required, because an unnamed course
    /// can't be recognised on the next visit and clutters Stats as a
    /// pseudo-venue.
    typealias CourseNamePrompt = (_ complete: @escaping (String?) -> Void) -> Void

    func resolve(
        at currentLocation: CLLocationCoordinate2D,
        progress: @escaping (Step) -> Void,
        coursePicker: @escaping ([CourseCandidate], @escaping (CourseCandidate?) -> Void) -> Void,
        scorecardPicker: @escaping ScorecardPicker,
        courseNamePrompt: @escaping CourseNamePrompt,
        completion: @escaping (Resolution?) -> Void
    ) {
        // Stash on the singleton so the deeper resolveScorecard call sites
        // can grab it without threading through every helper signature. A
        // single resolve() is in flight at a time on watchOS (round-start
        // is gated by user interaction), so this is safe.
        self.activeScorecardPicker = scorecardPicker
        self.activeCourseNamePrompt = courseNamePrompt
        self.activeOriginalName = nil
        progress(.searchingShared)
        Task {
            // Run BOTH lookups in parallel. Shared-only used to short-circuit
            // here when matchCount==1, but that auto-picked Wekiva when the
            // user's sim was at neighboring Sweetwater (Sweetwater wasn't in
            // shared yet but is in OSM). Always merge so the user sees
            // every nearby course and we only auto-pick when there's truly
            // a single candidate.
            async let sharedAsync = (try? await self.fetchSharedCoursesNear(currentLocation)) ?? []
            async let osmAsync = await self.fetchOSMCandidates(near: currentLocation)
            let shared = await sharedAsync
            let osm = await osmAsync
            ClientEventLogger.log("resolver.sharedQuery", detail: [
                "matchCount": .integer(shared.count)
            ])
            ClientEventLogger.log("resolver.osmQuery", detail: [
                "matchCount": .integer(osm.count)
            ])
            let merged = self.mergeCandidates(shared: shared, osm: osm)
            ClientEventLogger.log("resolver.merged", detail: [
                "candidateCount": .integer(merged.count)
            ])
            if merged.isEmpty {
                // Last-resort MapKit search inside resolveViaOSM also tries
                // .golf POIs when OSM/shared are both empty.
                self.resolveViaOSM(at: currentLocation, progress: progress, coursePicker: coursePicker, completion: completion)
                return
            }
            self.presentCandidates(merged, near: currentLocation, progress: progress, coursePicker: coursePicker, completion: completion)
        }
    }

    /// Run the OSM POI search and return its candidates as a list (no
    /// presentation). Empty on failure / no matches.
    private func fetchOSMCandidates(near currentLocation: CLLocationCoordinate2D) async -> [CourseCandidate] {
        await withCheckedContinuation { (cont: CheckedContinuation<[CourseCandidate], Never>) in
            osm.fetchCandidates(near: currentLocation) { result in
                guard case .success(let osmCandidates) = result else {
                    cont.resume(returning: [])
                    return
                }
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
                cont.resume(returning: candidates)
            }
        }
    }

    /// Merge shared and OSM candidates into a single list. A shared
    /// candidate that already has an osm_id matching an OSM candidate
    /// REPLACES that OSM candidate (shared keeps cached polygons + id, no
    /// re-fetch needed). All other shared and OSM candidates pass through.
    /// Sorted by distance.
    private func mergeCandidates(shared: [CourseCandidate], osm: [CourseCandidate]) -> [CourseCandidate] {
        var sharedOsmIds: Set<Int64> = []
        for c in shared {
            if case .shared(_, _, let osmId?) = c.source { sharedOsmIds.insert(osmId) }
        }
        let osmFiltered = osm.filter { c in
            if case .osm(let candidate) = c.source { return !sharedOsmIds.contains(candidate.osmId) }
            return true
        }
        return (shared + osmFiltered).sorted { $0.distanceMeters < $1.distanceMeters }
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
                self.presentCandidates(candidates, near: currentLocation, progress: progress, coursePicker: coursePicker, completion: completion)
            default:
                // OSM empty or errored — last-resort MapKit. If MapKit also
                // returns nothing, still surface the picker with just the
                // manual fallback so the user can start a no-course round.
                self.searchMapKitPOIs(near: currentLocation) { mapkit in
                    self.presentCandidates(mapkit, near: currentLocation, progress: progress, coursePicker: coursePicker, completion: completion)
                }
            }
        }
    }

    private func presentCandidates(_ candidates: [CourseCandidate],
                                   near currentLocation: CLLocationCoordinate2D,
                                   progress: @escaping (Step) -> Void,
                                   coursePicker: @escaping ([CourseCandidate], @escaping (CourseCandidate?) -> Void) -> Void,
                                   completion: @escaping (Resolution?) -> Void) {
        // Always append the manual ("Not at a course") candidate at the
        // end. The wide nearby radius (~3 miles) means single-result hits
        // can still be wrong (e.g. starting a round at home picks up the
        // nearest course down the road), AND the user might genuinely not
        // be on any course. Manual is the explicit opt-out — no OSM, no
        // scorecard, no shared-courses INSERT, just blob detection at the
        // user's current GPS. Cancel from the picker still bails entirely.
        let manualEntry = CourseCandidate(
            name: "Course not listed",
            coordinate: currentLocation,
            distanceMeters: 0,
            source: .manual
        )
        let withManual = candidates + [manualEntry]
        progress(.picking(withManual))
        coursePicker(withManual) { [weak self] chosen in
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
            resolveScorecard(courseName: candidate.name, near: candidate.coordinate, knownExternalCourseId: nil, courseId: nil) { scorecard in
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
        case .manual:
            // User is at a real course that isn't in our data (OSM didn't map
            // it, MapKit POI didn't surface it, no shared row exists yet).
            // Skip OSM lookup and scorecard search; blob detection still runs
            // (Stage 4 sets needsBlobDetection when osmData == nil) and
            // per-hole pars/coords come from HolePlacementView.
            //
            // The user names it and we DO insert a shared course row anchored
            // at their GPS, so the next round here matches by proximity under
            // that name. This replaces the old throwaway "Unlisted course":
            // that made a new anonymous course every visit, none of which
            // could ever be re-recognised, and Stats listed each one as if it
            // were a venue.
            ClientEventLogger.log("resolver.manual.picked", detail: [
                "lat": .double(candidate.coordinate.latitude),
                "lon": .double(candidate.coordinate.longitude)
            ])
            guard let prompt = activeCourseNamePrompt else {
                ClientEventLogger.log("resolver.manual.noNamePrompt")
                progress(.failed("Couldn't name this course"))
                completion(nil)
                return
            }
            prompt { [weak self] enteredName in
                guard let self else { return }
                let name = (enteredName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                // A name is required — cancelling or submitting blank aborts
                // the round rather than silently recreating a placeholder.
                guard !name.isEmpty else {
                    ClientEventLogger.log("resolver.manual.nameCancelled")
                    progress(.failed("Round cancelled"))
                    completion(nil)
                    return
                }
                let courseId = UUID()
                self.insertUserNamedCourse(id: courseId, name: name, center: candidate.coordinate)
                let resolution = Resolution(
                    courseId: courseId,
                    courseName: name,
                    courseCoordinate: candidate.coordinate,
                    osmData: nil,
                    tier: .none,
                    isExistingCourse: false,
                    scorecardCourse: nil
                )
                progress(.ready(resolution))
                completion(resolution)
            }
        }
    }

    /// INSERT a course the user named themselves. No `osm_id`, so this upserts
    /// on the primary key rather than `insertSharedCourse`'s `osm_id` conflict
    /// target. `center_lat`/`center_lon` are what `fetchSharedCoursesNear`
    /// matches on, so storing them is what makes the course re-findable on the
    /// next visit — that's the entire point of naming it.
    func insertUserNamedCourse(id: UUID, name: String, center: CLLocationCoordinate2D) {
        struct Row: Encodable {
            let id: String
            let name: String
            let center_lat: Double
            let center_lon: Double
        }
        let row = Row(id: id.uuidString, name: name,
                      center_lat: center.latitude, center_lon: center.longitude)
        Task {
            do {
                try await supabase.from("courses").upsert(row, onConflict: "id").execute()
                ClientEventLogger.log("resolver.userNamedCourseInserted", detail: [
                    "courseId": .string(id.uuidString),
                    "name": .string(name)
                ])
            } catch {
                ClientEventLogger.log("resolver.userNamedCourseInsertFailed", detail: [
                    "error": .string("\(error)")
                ])
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

            self.resolveScorecard(courseName: courseName, near: coordinate, knownExternalCourseId: externalCourseId, courseId: courseId) { scorecard in
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
            // courseId is nil here — this path REGISTERS a new shared course
            // row. By definition no skip votes exist yet (no prior user has
            // played this OSM course), so the skip-vote gate doesn't apply.
            self.resolveScorecard(courseName: userPickedName, near: userPickedCoord, knownExternalCourseId: nil, courseId: nil) { scorecard in
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
                                  courseId: UUID?,
                                  completion: @escaping (GCAPICourse?) -> Void) {
        // Cache fast-path: prior round at this course already resolved an
        // external_course_id. Reuse it without re-searching or asking the
        // user to re-pick. Picker only fires for fresh searches.
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
                // Cache miss — fall through to fresh search + picker.
                self.runScorecardSearchWithPicker(courseName: courseName, coordinate: coordinate, courseId: courseId, completion: completion)
            }
            return
        }
        runScorecardSearchWithPicker(courseName: courseName, coordinate: coordinate, courseId: courseId, completion: completion)
    }

    private func runScorecardSearchWithPicker(courseName: String,
                                              coordinate: CLLocationCoordinate2D,
                                              courseId: UUID?,
                                              completion: @escaping (GCAPICourse?) -> Void) {
        Task {
            // Consensus fast-path: if >=3 distinct users have all picked the
            // same external_course_id for this course (and >=75% agreement),
            // silent-pick that scorecard. Avoids re-asking each user the
            // same question once the community has converged on an answer.
            if let courseId = courseId,
               let consensusId = await self.consensusScorecardId(courseId: courseId) {
                ClientEventLogger.log("resolver.scorecard.consensusHit", detail: [
                    "courseId": .string(courseId.uuidString),
                    "externalCourseId": .integer(consensusId)
                ])
                if let stub = await Self.makeStubFromCachedTees(externalId: String(consensusId), name: courseName, coord: coordinate) {
                    completion(stub)
                    return
                }
                // Cached tees missing — fall through to a fresh search.
            }
            // Skip-vote gate: if >=3 distinct users have already picked
            // "Course not listed" for this course, don't burn an API call.
            if let courseId = courseId, await self.shouldSkipScorecardSearch(courseId: courseId) {
                ClientEventLogger.log("resolver.scorecard.skipVoteGate", detail: [
                    "courseId": .string(courseId.uuidString)
                ])
                completion(nil)
                return
            }
            await self.searchScorecard(courseName: courseName, near: coordinate) { ranked in
                guard let picker = self.activeScorecardPicker else {
                    completion(ranked.first?.course)
                    return
                }
                self.activeOriginalName = courseName
                picker(courseName, ranked) { picked in
                    // Record the pick BEFORE handing control back to the
                    // resolver completion. Previously this fired as an
                    // unstructured Task that awaited supabase.auth.session
                    // concurrently with startRound's own auth-touching
                    // calls — racy enough to crash the watch app
                    // mid-tee-pick. Keeping the write awaited here means
                    // no concurrent auth access during round-start.
                    if let courseId = courseId {
                        Task {
                            if let pick = picked {
                                await self.recordScorecardPick(courseId: courseId, externalCourseId: pick.id)
                            } else {
                                await self.recordScorecardSkip(courseId: courseId)
                            }
                            completion(picked)
                        }
                    } else {
                        completion(picked)
                    }
                }
            }
        }
    }

    /// Threshold for cross-user scorecard consensus. Same as canonical
    /// hole-pick model — 3 distinct users with >=75% agreement.
    private static let scorecardConsensusUserCount = 3
    private static let scorecardConsensusAgreement = 0.75

    private func consensusScorecardId(courseId: UUID) async -> Int? {
        struct Row: Decodable {
            let user_id: UUID
            let external_course_id: Int64
        }
        do {
            let rows: [Row] = try await supabase
                .from("course_scorecard_picks")
                .select("user_id,external_course_id")
                .eq("course_id", value: courseId.uuidString)
                .execute()
                .value
            // Distinct users (one row per user via PK), bucket by external id.
            let counts = Dictionary(grouping: rows, by: { $0.external_course_id }).mapValues { $0.count }
            let totalUsers = rows.count
            guard totalUsers >= Self.scorecardConsensusUserCount,
                  let (modalId, modalCount) = counts.max(by: { $0.value < $1.value }) else { return nil }
            let share = Double(modalCount) / Double(totalUsers)
            guard share >= Self.scorecardConsensusAgreement else { return nil }
            return Int(modalId)
        } catch {
            return nil
        }
    }

    private static func makeStubFromCachedTees(externalId: String, name: String, coord: CLLocationCoordinate2D) async -> GCAPICourse? {
        do {
            let cached = try await GolfCourseAPIService.shared.cachedTees(forExternalCourseId: externalId)
            return makeStubCourse(externalId: externalId, name: name, coord: coord, cachedTees: cached)
        } catch {
            return nil
        }
    }

    private func recordScorecardPick(courseId: UUID, externalCourseId: Int) async {
        guard let uid = (try? await supabase.auth.session.user.id) else { return }
        struct Row: Encodable {
            let user_id: String
            let course_id: String
            let external_course_id: Int
            let updated_at: String
        }
        let row = Row(
            user_id: uid.uuidString,
            course_id: courseId.uuidString,
            external_course_id: externalCourseId,
            updated_at: ISO8601DateFormatter().string(from: Date())
        )
        do {
            try await supabase
                .from("course_scorecard_picks")
                .upsert(row, onConflict: "user_id,course_id")
                .execute()
            ClientEventLogger.log("resolver.scorecard.pickRecorded", detail: [
                "courseId": .string(courseId.uuidString),
                "externalCourseId": .integer(externalCourseId)
            ])
        } catch {
            dprint("[RoundResolver] record scorecard pick failed: \(error)")
        }
    }

    /// Threshold for cross-user "Course not listed" votes. Once this many
    /// distinct users have skipped, future rounds at the same course skip
    /// the API call entirely.
    private static let scorecardSkipVoteThreshold = 3

    private func shouldSkipScorecardSearch(courseId: UUID) async -> Bool {
        struct Row: Decodable { let user_id: UUID }
        do {
            let rows: [Row] = try await supabase
                .from("course_scorecard_skips")
                .select("user_id")
                .eq("course_id", value: courseId.uuidString)
                .execute()
                .value
            let distinctUsers = Set(rows.map { $0.user_id }).count
            return distinctUsers >= Self.scorecardSkipVoteThreshold
        } catch {
            // On error, don't gate — let the search proceed.
            return false
        }
    }

    private func recordScorecardSkip(courseId: UUID) async {
        guard let uid = (try? await supabase.auth.session.user.id) else { return }
        struct Row: Encodable {
            let user_id: String
            let course_id: String
        }
        let row = Row(user_id: uid.uuidString, course_id: courseId.uuidString)
        do {
            try await supabase
                .from("course_scorecard_skips")
                .upsert(row, onConflict: "user_id,course_id")
                .execute()
            ClientEventLogger.log("resolver.scorecard.skipRecorded", detail: [
                "courseId": .string(courseId.uuidString)
            ])
        } catch {
            dprint("[RoundResolver] record scorecard skip failed: \(error)")
        }
    }

    /// Strip golf-jargon + stopwords from an OSM course name so the GCAPI
    /// substring search isn't anchored to noise words like "Country Club"
    /// or "(The Villages)". E.g.
    ///   "Sweetwater Country Club"   → "sweetwater"
    ///   "Bay Hill Golf Club"        → "bay hill"
    ///   "Country Club of Mount Dora" → "mount dora"
    /// The 25-result API cap means generic stripped queries (`country`,
    /// `club`, `golf`) would burn through the cap with random results,
    /// but the strip set deliberately includes ONLY noise words so what's
    /// left is always the discriminating part of the name.
    static func stripCourseName(_ name: String) -> String {
        let stopwords: Set<String> = ["the","of","and","at","on","in","a","an","&"]
        let jargon: Set<String> = [
            "country","club","golf","course","courses","resort","national",
            "international","municipal","championship","executive","public",
            "gc","cc","center","centre"
        ]
        // Drop parenthesized branding like "(The Villages)" first.
        var s = name.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        // Punctuation → space, keep apostrophes/hyphens inside words.
        s = s.replacingOccurrences(of: #"[^\w\s'-]"#, with: " ", options: .regularExpression)
        let toks = s.lowercased().split(whereSeparator: { $0.isWhitespace })
            .map { token -> String in
                var t = String(token)
                if t.hasSuffix("'s") { t.removeLast(2) }
                return t
            }
            .filter { !$0.isEmpty && !stopwords.contains($0) && !jargon.contains($0) }
        return toks.joined(separator: " ")
    }

    /// Cached geocode lookup for "city|state|country" → coordinate. Stored
    /// in UserDefaults so repeat searches across rounds don't re-hit
    /// CLGeocoder. Negative results (failed geocode) are cached as nil
    /// values so we don't keep retrying. The cache never expires for the
    /// session — city centroids don't move.
    private static let geocodeCacheKey = "scorecardGeocodeCache_v1"

    private static func cachedGeocode(_ key: String) -> CLLocationCoordinate2D?? {
        guard let dict = UserDefaults.standard.dictionary(forKey: geocodeCacheKey),
              let entry = dict[key] as? [String: Any] else { return .none }
        if let neg = entry["negative"] as? Bool, neg { return .some(nil) }
        guard let lat = entry["lat"] as? Double, let lon = entry["lon"] as? Double else { return .none }
        return .some(CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    private static func writeCachedGeocode(_ key: String, coord: CLLocationCoordinate2D?) {
        var dict = UserDefaults.standard.dictionary(forKey: geocodeCacheKey) ?? [:]
        if let c = coord {
            dict[key] = ["lat": c.latitude, "lon": c.longitude]
        } else {
            dict[key] = ["negative": true]
        }
        UserDefaults.standard.set(dict, forKey: geocodeCacheKey)
    }

    /// Geocode city,state,country via CLGeocoder. Cached. Returns nil when
    /// city is missing/Unknown OR geocoder fails.
    private func geocodeCityState(city: String?, state: String?, country: String?) async -> CLLocationCoordinate2D? {
        let cleanCity = city?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanState = state?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCountry = country?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cleanCity, !cleanCity.isEmpty, cleanCity.lowercased() != "unknown",
              let cleanState, !cleanState.isEmpty, cleanState.lowercased() != "unknown" else {
            return nil
        }
        let key = [cleanCity, cleanState, cleanCountry ?? ""].joined(separator: "|").lowercased()
        if case let .some(cached) = Self.cachedGeocode(key) { return cached }

        let address = [cleanCity, cleanState, cleanCountry].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.geocodeAddressString(address)
            let coord = placemarks.first?.location?.coordinate
            Self.writeCachedGeocode(key, coord: coord)
            return coord
        } catch {
            Self.writeCachedGeocode(key, coord: nil)
            return nil
        }
    }

    /// Run the GCAPI search using the stripped name and return all
    /// candidates ranked into five buckets (see ScorecardCandidate.Bucket).
    /// Bucket 1+2 = high-confidence picks; bucket 3 = could-be; 4+5 = unlikely.
    /// Empty list means the search returned zero candidates total.
    private func searchScorecard(courseName: String,
                                 near coordinate: CLLocationCoordinate2D,
                                 completion: @escaping ([ScorecardCandidate]) -> Void) async {
        // Try GCAPI with the OSM-stripped name AND the MapKit POI name
        // (when different). GCAPI substring-matches on club_name only, and
        // OSM names often disagree with what Apple/GCAPI call the same
        // physical course (Kissimmee Oaks vs Oaks National). MapKit and
        // GCAPI tend to agree, so the MapKit-derived query catches the
        // OSM-name-mismatch cases without user input.
        let osmQuery = Self.stripCourseName(courseName)
        let mapKitName = await self.closestMapKitGolfName(near: coordinate)
        let mapKitQuery = mapKitName.map(Self.stripCourseName) ?? ""
        var queries: [String] = []
        if !osmQuery.isEmpty { queries.append(osmQuery) }
        if !mapKitQuery.isEmpty && mapKitQuery != osmQuery { queries.append(mapKitQuery) }
        guard !queries.isEmpty else {
            ClientEventLogger.log("resolver.scorecard.stripEmpty", detail: [
                "originalName": .string(courseName),
                "mapKitName": mapKitName.map { .string($0) } ?? .null
            ])
            completion([])
            return
        }
        ClientEventLogger.log("resolver.scorecard.searchStart", detail: [
            "originalName": .string(courseName),
            "mapKitName": mapKitName.map { .string($0) } ?? .null,
            "queries": .string(queries.joined(separator: "|"))
        ])
        do {
            // Run all queries, dedupe by GCAPI course id (a single course can
            // surface under both queries).
            var seen: Set<Int> = []
            var candidates: [GCAPICourse] = []
            for q in queries {
                let batch = try await GolfCourseAPIService.shared.search(query: q)
                for c in batch where !seen.contains(c.id) {
                    seen.insert(c.id)
                    candidates.append(c)
                }
            }
            let userLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            var ranked: [ScorecardCandidate] = []
            var droppedCount = 0
            for c in candidates {
                // Resolve a candidate coord — real API coord first, falling
                // back to a geocoded city/state centroid when API has none.
                var resolved: CLLocationCoordinate2D? = c.coordinate
                if resolved == nil {
                    resolved = await self.geocodeCityState(
                        city: c.location?.city,
                        state: c.location?.state,
                        country: c.location?.country
                    )
                }
                guard let coord = resolved else {
                    // No coord at all (no API coord, no city/state to geocode).
                    // Show in the picker — user judges from name + city/state.
                    ranked.append(ScorecardCandidate(course: c, bucket: .noLocation, distanceMeters: nil))
                    continue
                }
                let d = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                    .distance(from: userLoc)
                if d <= Self.scorecardProximityMeters {
                    ranked.append(ScorecardCandidate(course: c, bucket: .inRange, distanceMeters: d))
                } else {
                    droppedCount += 1
                }
            }
            // Stubs (no tee data) STAY visible — at multi-course resorts a
            // sibling entry may have full data while the user's actual
            // course is a stub, and silently substituting would be worse
            // than showing both with the user picking. Picker labels stubs
            // with "(no scorecard data)" so the user knows what they're
            // selecting.
            ranked.sort { l, r in
                if l.bucket != r.bucket { return l.bucket < r.bucket }
                return (l.distanceMeters ?? .infinity) < (r.distanceMeters ?? .infinity)
            }
            ClientEventLogger.log("resolver.scorecard.searchRanked", detail: [
                "queries": .string(queries.joined(separator: "|")),
                "rawCount": .integer(candidates.count),
                "visibleCount": .integer(ranked.count),
                "inRange": .integer(ranked.filter { $0.bucket == .inRange }.count),
                "noLocation": .integer(ranked.filter { $0.bucket == .noLocation }.count),
                "droppedOutOfRange": .integer(droppedCount)
            ])
            completion(ranked)
        } catch {
            dprint("[RoundResolver] GolfCourseAPI search failed: \(error)")
            completion([])
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

    /// Returns the closest MapKit golf-POI name to `coordinate` (within
    /// 1500m), or nil. Used as an alternative course-name source for the
    /// GCAPI scorecard search — when OSM and MapKit/GCAPI disagree on the
    /// course name, MapKit usually agrees with GCAPI's listing (Kissimmee
    /// Oaks vs Oaks National). Querying GCAPI with both names catches the
    /// disagreement cases without forcing the user to type anything.
    func closestMapKitGolfName(near coordinate: CLLocationCoordinate2D) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            searchMapKitPOIs(near: coordinate) { candidates in
                cont.resume(returning: candidates.first?.name)
            }
        }
    }

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
