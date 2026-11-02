import Foundation

extension DataStore {

    // MARK: - Demo Data

    /// Adds a fixed set of fake courses + rounds so visualizations have
    /// something to render. Idempotent — running twice replaces prior demo data.
    func seedDemoData() {
        clearDemoData()
        let generated = DemoDataSeeder.generate(
            clubTypes: clubTypes,
            availableClubs: availableClubs
        )
        courses.append(contentsOf: generated.courses)
        rounds.append(contentsOf: generated.rounds)
        saveCourses()
        saveRounds()
        for course in generated.courses {
            SupabaseSync.shared.upsertCourse(course)
            for hole in course.holes {
                hole.ownerId = currentUserUUID
                SupabaseSync.shared.upsertMyCourseHole(hole, courseId: course.id)
            }
        }
        for round in generated.rounds {
            SupabaseSync.shared.upsertRound(round)
            SupabaseSync.shared.upsertRoundHoles(round)
            for stroke in round.strokes {
                SupabaseSync.shared.upsertStroke(stroke, roundId: round.id)
            }
        }
        rebuildPlayerStats()
    }

    /// Removes any course whose name starts with the demo prefix, along with
    /// all rounds tied to those courses. Leaves real data alone.
    func clearDemoData() {
        let demoCourseIds = Set(
            courses.filter { $0.name.hasPrefix(DemoDataSeeder.demoPrefix) }.map { $0.id }
        )
        guard !demoCourseIds.isEmpty else { return }
        let demoRoundIds = rounds.filter { demoCourseIds.contains($0.courseId) }.map { $0.id }
        rounds.removeAll { demoCourseIds.contains($0.courseId) }
        courses.removeAll { demoCourseIds.contains($0.id) }
        saveCourses()
        saveRounds()
        // Server cascades clean up child rows (strokes, holes, targets).
        for id in demoRoundIds {
            SupabaseSync.shared.deleteRound(id: id)
        }
        for id in demoCourseIds {
            SupabaseSync.shared.deleteCourse(id: id)
        }
        rebuildPlayerStats()
    }
}
