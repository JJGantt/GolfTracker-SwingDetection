import Foundation
import CoreLocation
import SwiftData

// Courses and their holes on the phone: fetching a server course, editing
// holes, and carrying hole edits into the round in progress.
extension DataStore {

    /// Direct Supabase fetch for a course by id, with local SwiftData
    /// insert. Used when the watch refers to a shared-courses row that the
    /// iPhone hasn't received via Realtime yet. Returns the freshly-inserted
    /// Course on success, nil if the row doesn't exist or the fetch fails.
    @MainActor
    func fetchAndInsertCourse(by courseId: UUID) async -> Course? {
        guard let context = self.context else { return nil }
        struct Row: Decodable {
            let id: UUID
            let name: String
            let center_lat: Double?
            let center_lon: Double?
            let osm_id: Int64?
            let external_course_id: String?
            // Decoded loosely — the OSM polygon shape is JSONB; we only
            // need the basic course fields here for blob detection.
        }
        do {
            let rows: [Row] = try await SupabaseManager.shared
                .from("courses")
                .select("id,name,center_lat,center_lon,osm_id,external_course_id")
                .eq("id", value: courseId.uuidString)
                .limit(1)
                .execute()
                .value
            guard let row = rows.first else {
                ClientEventLogger.log("blob.request.fetchCourse.missing", detail: [
                    "courseId": .string(courseId.uuidString)
                ])
                return nil
            }
            let course = Course(
                id: row.id,
                name: row.name,
                centerLat: row.center_lat,
                centerLon: row.center_lon,
                osmId: row.osm_id,
                externalCourseId: row.external_course_id
            )
            // The course's hole rows too, under their server ids. A course
            // brought in without them gets holes built locally with new ids,
            // and the server's then arrive as a second set.
            struct HoleRow: Decodable {
                let id: UUID
                let number: Int
                let latitude: Double?
                let longitude: Double?
                let par: Int?
                let owner_id: UUID?
            }
            let fetched: [HoleRow] = try await SupabaseManager.shared
                .from("holes")
                .select("id,number,latitude,longitude,par,owner_id")
                .eq("course_id", value: courseId.uuidString)
                .execute()
                .value
            // One per number; the user's own hole beats the shared one.
            let holeRows = Dictionary(grouping: fetched, by: \.number).values.compactMap { rows in
                rows.first { $0.owner_id != nil } ?? rows.first
            }
            course.holes = holeRows.map { r in
                let id = r.id
                let hole = (try? context.fetch(FetchDescriptor<Hole>(predicate: #Predicate { $0.id == id })))?.first
                    ?? Hole(id: r.id, number: r.number)
                hole.number = r.number
                hole.latitude = r.latitude
                hole.longitude = r.longitude
                hole.par = r.par
                hole.ownerId = r.owner_id
                return hole
            }
            context.insert(course)
            try? context.save()
            ClientEventLogger.log("blob.request.fetchCourse.inserted", detail: [
                "courseId": .string(courseId.uuidString),
                "name": .string(row.name)
            ])
            // Refresh the cached `courses` array
            loadCourses()
            return course
        } catch {
            ClientEventLogger.log("blob.request.fetchCourse.error", detail: [
                "courseId": .string(courseId.uuidString),
                "error": .string("\(error)")
            ])
            return nil
        }
    }

    /// Decoded OSM data for a course, sourced from `Course.osmPolygons`
    /// (already populated by `RoundResolver` / `OSMCourseService`). The
    /// watch keeps a separate `[UUID: OSMCourseData]` dict; on iOS we
    /// just decode on demand from the SwiftData column. Returns nil if
    /// the course has no OSM coverage or the payload fails to decode.
    func osmCourseData(forCourseId id: UUID) -> OSMCourseData? {
        guard let course = courses.first(where: { $0.id == id }),
              let raw = course.osmPolygons else { return nil }
        return try? JSONDecoder().decode(OSMCourseData.self, from: raw)
    }

    func addCourse(name: String) {
        let course = Course(name: name, holes: [])
        courses.append(course)
        saveCourses()
        SupabaseSync.shared.upsertCourse(course)
    }

    func deleteCourse(_ course: Course) {
        guard !course.isShared else { return }
        courses.removeAll { $0.id == course.id }
        saveCourses()
        SupabaseSync.shared.deleteCourse(id: course.id)
    }

    func updateCourseInfo(_ course: Course, name: String, rating: Double?, slope: Int?) {
        guard !course.isShared, let index = courses.firstIndex(where: { $0.id == course.id }) else { return }
        courses[index].name = name
        courses[index].rating = rating
        courses[index].slope = slope
        saveCourses()
        SupabaseSync.shared.upsertCourse(courses[index])
    }

    func updateCourseCity(_ course: Course) {
        guard courses.firstIndex(where: { $0.id == course.id }) != nil,
              let coordinate = course.coordinate else { return }

        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        let courseId = course.id
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            guard let self = self,
                  let placemark = placemarks?.first,
                  let city = placemark.locality else { return }

            DispatchQueue.main.async {
                if let currentIndex = self.courses.firstIndex(where: { $0.id == courseId }) {
                    self.courses[currentIndex].city = city
                    self.saveCourses()
                    SupabaseSync.shared.upsertCourse(self.courses[currentIndex])
                }
            }
        }
    }

    func addHole(to course: Course, coordinate: CLLocationCoordinate2D, par: Int? = nil, userLocation: CLLocationCoordinate2D? = nil) {
        guard let index = courses.firstIndex(where: { $0.id == course.id }) else { return }
        let holeNumber = courses[index].holes.count + 1
        let hole = Hole(number: holeNumber, coordinate: coordinate, par: par)
        hole.ownerId = currentUserUUID
        courses[index].holes.append(hole)
        saveCourses()
        SupabaseSync.shared.upsertMyCourseHole(hole, courseId: course.id)

        dprint("📱 [DataStore] Added hole #\(holeNumber) to course \(course.name)")

        // Update city if this is the first hole or if city is not set
        if courses[index].city == nil {
            updateCourseCity(courses[index])
        }

        // Update active round with new hole data and resync to Watch
        updateActiveRoundHoles(for: course)
    }

    /// Carries course hole edits into the round in progress at that course,
    /// matched by hole number. The round has its own `Hole`s, never the
    /// course's, so this copies values and adds or removes the round's holes
    /// to match. Finished rounds keep the holes they were played with.
    private func updateActiveRoundHoles(for course: Course) {
        guard let round = rounds.filter({ $0.courseId == course.id && $0.endedAt == nil })
                .max(by: { $0.date < $1.date }),
              let courseHoles = courses.first(where: { $0.id == course.id })?.holes.oneByNumber else { return }

        var unmatched = Dictionary(round.holes.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        var added: [Int] = []
        for courseHole in courseHoles {
            if let roundHole = unmatched.removeValue(forKey: courseHole.number) {
                roundHole.latitude = courseHole.latitude
                roundHole.longitude = courseHole.longitude
                roundHole.par = courseHole.par
            } else {
                round.holes.append(courseHole.roundCopy(roundId: round.id, teeId: round.selectedTeeId))
                added.append(courseHole.number)
            }
        }
        for extra in unmatched.values {
            round.holes.removeAll { $0.id == extra.id }
            context?.delete(extra)
            SupabaseSync.shared.deleteRoundHole(id: extra.id)
        }

        // If a new hole was added, point the round at it
        if let newest = added.max() {
            round.currentHoleNumber = newest
        }
        saveRounds()
        SupabaseSync.shared.upsertRound(round)
        SupabaseSync.shared.upsertRoundHoles(round)
    }

    /// Deleting and renumbering rewrite every hole's number, so they apply to
    /// a course of the user's own holes only (`canRenumberHoles`): a shared
    /// hole's number is OSM's, and no client changes it.
    func canRenumberHoles(in course: Course) -> Bool {
        !course.holes.contains { $0.isShared }
    }

    func deleteHole(_ hole: Hole, from course: Course) {
        guard let courseIndex = courses.firstIndex(where: { $0.id == course.id }),
              canRenumberHoles(in: courses[courseIndex]) else { return }
        let lastNumber = courses[courseIndex].holes.map(\.number).max() ?? hole.number
        courses[courseIndex].holes.removeAll { $0.id == hole.id }
        // Renumber remaining holes. SwiftData relationship arrays are
        // unordered — sort by current number before reassigning.
        let remaining = courses[courseIndex].holes.sorted { $0.number < $1.number }
        for (i, h) in remaining.enumerated() {
            h.number = i + 1
        }
        saveCourses()
        // The user's holes are keyed by number: every number below the last
        // now holds what the next hole held, and the last number goes.
        for h in remaining {
            SupabaseSync.shared.upsertMyCourseHole(h, courseId: course.id)
        }
        SupabaseSync.shared.deleteMyCourseHole(courseId: course.id, number: lastNumber)
        updateActiveRoundHoles(for: course)
    }

    func updateHole(_ hole: Hole, in course: Course, newCoordinate: CLLocationCoordinate2D, par: Int? = nil) {
        guard let courseIndex = courses.firstIndex(where: { $0.id == course.id }),
              let holeIndex = courses[courseIndex].holes.firstIndex(where: { $0.id == hole.id }) else { return }
        courses[courseIndex].holes[holeIndex].latitude = newCoordinate.latitude
        courses[courseIndex].holes[holeIndex].longitude = newCoordinate.longitude
        if let par = par {
            courses[courseIndex].holes[holeIndex].par = par
        }
        // Moving a hole makes it the user's own, shared or not.
        courses[courseIndex].holes[holeIndex].ownerId = currentUserUUID
        saveCourses()
        SupabaseSync.shared.upsertMyCourseHole(courses[courseIndex].holes[holeIndex], courseId: course.id)
        updateActiveRoundHoles(for: course)
    }

    func renumberHole(_ hole: Hole, in course: Course, newNumber: Int) {
        guard let courseIndex = courses.firstIndex(where: { $0.id == course.id }),
              canRenumberHoles(in: courses[courseIndex]) else { return }

        // SwiftData relationship arrays are unordered — work on a copy
        // sorted by current number, move the hole, then reassign.
        var sorted = courses[courseIndex].holes.sorted { $0.number < $1.number }
        guard let holeIndex = sorted.firstIndex(where: { $0.id == hole.id }) else { return }

        let clampedNumber = max(1, min(newNumber, sorted.count))
        let removedHole = sorted.remove(at: holeIndex)
        sorted.insert(removedHole, at: clampedNumber - 1)

        for (i, h) in sorted.enumerated() {
            h.number = i + 1
        }

        saveCourses()
        for h in sorted {
            SupabaseSync.shared.upsertMyCourseHole(h, courseId: course.id)
        }
        updateActiveRoundHoles(for: course)
    }
}
