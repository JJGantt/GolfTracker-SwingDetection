import Foundation
import CoreLocation

// Starting, ending and deleting rounds, and the round's own state (current
// hole, completed holes).
extension DataStore {

    // MARK: - Round Management

    func startRound(
        for course: Course,
        runHoleDetection: Bool = true,
        useHoleDetectionTestCoordinates: Bool = false,
        selectedTeeId: UUID? = nil
    ) -> Round {
        dprint("📱 [DataStore] startRound called for course: \(course.name)")
        // Auto-end any prior in-progress round — starting a new round
        // implies the old one is finished, regardless of whether the user
        // hit End Round. Avoids stale "ongoing" rounds piling up.
        endAnyOngoingRound(reason: "new round starting")
        // The round gets its own copies of the course's holes, as on the watch
        // and in `round_holes` (see `Round.holes`).
        let roundId = UUID()
        let round = Round(
            id: roundId,
            courseId: course.id,
            courseName: course.name,
            holes: course.holes.oneByNumber.map { $0.roundCopy(roundId: roundId, teeId: selectedTeeId) },
            holeDetectionEnabled: runHoleDetection,
            locationTestModeEnabled: useHoleDetectionTestCoordinates,
            selectedTeeId: selectedTeeId
        )
        rounds.append(round)
        saveRounds()

        // Round + clubs now sync via DB (Realtime + SwiftData) — no WC push needed.
        SupabaseSync.shared.upsertRound(round)
        SupabaseSync.shared.upsertRoundHoles(round)

        // Start path + altitude capture for the round. Hole-number provider
        // reads the round's currentHoleNumber live so each sample is tagged
        // with the hole the user is actually on at capture time.
        if let uid = AuthManager.shared.currentUserId {
            let roundId = round.id
            LocationManager.shared.startPathRecording(roundId: roundId, userId: uid) { [weak self] in
                guard let self,
                      let r = self.rounds.first(where: { $0.id == roundId }) else { return 1 }
                return r.currentHoleNumber
            }
        } else {
            ClientEventLogger.log("altitude.recording.skipped.noUid", detail: [
                "roundId": .string(round.id.uuidString)
            ])
        }

        // Live elevation-to-green readout. Load the cache for this
        // course's holes (one batched query) then start the readout
        // service so it'll publish a Δ as soon as enough crossings land.
        let elevationCourseId = course.id
        Task { @MainActor in
            await HoleHeightCellCache.shared.loadForCourse(courseId: elevationCourseId)
            ElevationReadout.shared.start(courseId: elevationCourseId)
            await HistoricalFirstStrokeCache.shared.loadForCourse(
                courseId: elevationCourseId
            )
        }

        if runHoleDetection {
            startHoleDetection(
                for: course,
                overrideCenter: useHoleDetectionTestCoordinates ? holeDetectionTestCenter : nil,
                allowCache: !useHoleDetectionTestCoordinates,
                persistResult: !useHoleDetectionTestCoordinates
            )
        }

        return round
    }

    // MARK: - GPS Round Start


    func pickTee(_ tee: CachedCourseTee?) {
        let resolution = pendingTeePickerResolution
        pendingTeePicker = nil
        pendingTeePickerResolution = nil
        guard let resolution else { return }
        startRound(from: resolution, selectedTeeId: tee?.id)
    }

    func handleResolved(_ resolution: RoundResolver.Resolution) {
        guard let scorecard = resolution.scorecardCourse else {
            startRound(from: resolution, selectedTeeId: nil)
            return
        }
        Task {
            let tees = (try? await GolfCourseAPIService.shared.cachedTees(
                forExternalCourseId: String(scorecard.id)
            )) ?? []
            await MainActor.run {
                if tees.isEmpty {
                    self.startRound(from: resolution, selectedTeeId: nil)
                } else {
                    self.pendingTeePickerResolution = resolution
                    self.pendingTeePicker = PendingTeePicker(
                        courseName: resolution.courseName,
                        tees: tees
                    )
                }
            }
        }
    }

    private func startRound(from resolution: RoundResolver.Resolution, selectedTeeId: UUID?) {
        Task { @MainActor in
            let course = await self.courseForRound(resolution)
            _ = self.startRound(for: course, runHoleDetection: resolution.tier != .full, selectedTeeId: selectedTeeId)
        }
    }

    /// The course a resolved round starts on: the local one, else the server's
    /// (with its hole rows), else a new one built from the resolution. Building
    /// a new local copy of a course the server already had gave every hole a
    /// second id: `holes` is unique on (course_id, number), so the server kept
    /// its own rows, and they arrived later as more holes.
    private func courseForRound(_ resolution: RoundResolver.Resolution) async -> Course {
        let osmEncoded = resolution.osmData.flatMap { try? JSONEncoder().encode($0) }
        var found = courses.first(where: { $0.id == resolution.courseId })
        if found == nil {
            found = await fetchAndInsertCourse(by: resolution.courseId)
        }
        let isNew = found == nil
        let course = found ?? Course(
            id: resolution.courseId,
            name: resolution.courseName,
            centerLat: resolution.courseCoordinate.latitude,
            centerLon: resolution.courseCoordinate.longitude,
            osmId: resolution.osmId,
            osmPolygons: osmEncoded
        )
        if let osmEncoded { course.osmPolygons = osmEncoded }
        if course.osmId == nil { course.osmId = resolution.osmId }
        if course.holes.isEmpty, resolution.tier == .full, let osm = resolution.osmData {
            course.holes = osm.holes
                .compactMap { h -> Hole? in
                    guard let ref = h.ref, let n = Int(ref) else { return nil }
                    return Hole(
                        number: n,
                        coordinate: CLLocationCoordinate2D(
                            latitude: h.greenPoint.latitude,
                            longitude: h.greenPoint.longitude
                        ),
                        par: h.par
                    )
                }
                .sorted { $0.number < $1.number }
            // These are OSM's holes, so the server builds the shared rows
            // itself. For a new course the resolver asks it once the course
            // row exists.
            if !isNew {
                SupabaseSync.shared.deriveOSMCourseHoles(courseId: course.id)
            }
        }
        if isNew {
            courses.append(course)
        }
        saveCourses()
        if isNew {
            SupabaseSync.shared.upsertCourse(course)
        }
        return course
    }

    /// Start a round with no GPS fix at all. The user still names the course,
    /// but with no coordinate there's nothing to anchor it to, so it can't be
    /// matched by proximity next time. This used to silently create a course
    /// called "Quick Start" — one per tap, each showing up in Stats as its own
    /// venue.
    func startManualQuickRound() {
        pendingCourseNameCompletion = { [weak self] entered in
            guard let self = self else { return }
            let name = (entered ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }   // cancelled — no round
            let newCourse = Course(name: name)
            self.courses.append(newCourse)
            self.saveCourses()
            SupabaseSync.shared.upsertCourse(newCourse)
            _ = self.startRound(for: newCourse, runHoleDetection: false)
        }
        pendingCourseNamePrompt = true
    }

    func deleteRound(_ round: Round) {
        let wasInProgress = round.endedAt == nil
        rounds.removeAll { $0.id == round.id }
        // Delete from SwiftData too, not just the published array. Without
        // this the row survives in the store and `loadRounds()` re-fetches it
        // on the next launch — the round only really disappeared when the
        // Supabase delete echoed back through Realtime's `applyRound(.delete)`,
        // so deleting offline (or missing the event) resurrected it.
        // Cascade takes the round's strokes, targets and holes; the holes are
        // the round's own copies, never the course's.
        if let context = context {
            context.delete(round)
        }
        saveRounds()
        SupabaseSync.shared.deleteRound(id: round.id)
        rebuildPlayerStats()
        if currentRoundId == round.id { currentRoundId = nil }

        // Deleting an in-progress round needs the same teardown as endRound,
        // minus the elevation fold-in (the round's data is being discarded).
        if wasInProgress {
            Task { @MainActor in
                ElevationReadout.shared.stop()
                HoleHeightCellCache.shared.clear()
                HistoricalFirstStrokeCache.shared.clear()
            }
            Task {
                await LocationManager.shared.stopPathRecording()
            }
        }
    }

    func hasRounds(for course: Course) -> Bool {
        return rounds.contains { $0.courseId == course.id }
    }

    // MARK: - Round State Management (with automatic sync)

    func setCurrentHole(for round: Round, number: Int) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }) else { return }

        rounds[roundIndex].currentHoleNumber = number
        rounds[roundIndex].lastActivityAt = Date()
        saveRounds()
        ClientEventLogger.logBattery(hole: number)

        // Mirror to Supabase (Realtime fans out to the other device)
        SupabaseSync.shared.updateCurrentHole(rounds[roundIndex])
    }

    /// Mark a round finished. Manual button + lifecycle sweep both call this.
    /// Idempotent: setting `endedAt` on an already-ended round is a no-op.
    func endRound(_ round: Round, reason: String = "manual") {
        guard let idx = rounds.firstIndex(where: { $0.id == round.id }) else { return }
        guard rounds[idx].endedAt == nil else { return }
        rounds[idx].endedAt = Date()
        saveRounds()
        dprint("📱 [DataStore] Ended round \(round.id) — \(reason)")
        SupabaseSync.shared.upsertRound(rounds[idx])
        // Drain the upload queue in the background; queue is disk-
        // persistent so the next round picks up any leftovers. After the
        // drain completes, fold this round's altitude rows into the
        // shared `hole_height_cells` table so future rounds (anyone's)
        // can calibrate against them.
        let foldInCourseId = rounds[idx].courseId
        let foldInRoundId = rounds[idx].id
        let skipFoldIn = rounds[idx].locationTestModeEnabled == true
        Task { @MainActor in
            ElevationReadout.shared.stop()
            HoleHeightCellCache.shared.clear()
            HistoricalFirstStrokeCache.shared.clear()
        }
        Task {
            await LocationManager.shared.stopPathRecording()
            if !skipFoldIn {
                await ElevationFoldIn.run(courseId: foldInCourseId,
                                          roundId: foldInRoundId)
            }
        }
        if currentRoundId == round.id { currentRoundId = nil }
    }

    /// End every in-progress round. Used by startRound — once the user
    /// starts a new round, any prior open round is implicitly over.
    func endAnyOngoingRound(reason: String) {
        for r in rounds where r.endedAt == nil {
            endRound(r, reason: reason)
        }
    }

    func completeHole(in round: Round, holeNumber: Int) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }) else { return }

        rounds[roundIndex].completedHoles.insert(holeNumber)
        saveRounds()

        // Mirror to Supabase (Realtime fans out to the other device)
        SupabaseSync.shared.upsertRound(rounds[roundIndex])
    }

    func reopenHole(in round: Round, holeNumber: Int) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }) else { return }

        rounds[roundIndex].completedHoles.remove(holeNumber)
        saveRounds()

        // Mirror to Supabase (Realtime fans out to the other device)
        SupabaseSync.shared.upsertRound(rounds[roundIndex])
    }
}
