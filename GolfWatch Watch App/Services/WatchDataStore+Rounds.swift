import Foundation
import CoreLocation
import SwiftData

// Starting and ending rounds, and the current round's state.
extension WatchDataStore {

    // MARK: - Round State Management

    func setCurrentHole(number: Int) {
        guard let round = currentRound, let context = context else { return }
        round.currentHoleNumber = number
        round.lastActivityAt = Date()
        try? context.save()
        SupabaseSync.shared.updateCurrentHole(round)
        ClientEventLogger.logBattery(hole: number)
        objectWillChange.send()
    }

    /// Mark the current round finished. Manual button + lifecycle sweep both
    /// route through here. Idempotent — re-ending an already-ended round
    /// is a no-op.
    func endRound(reason: String = "manual") {
        guard let round = currentRound, let context = context else { return }
        guard round.endedAt == nil else { return }
        round.endedAt = Date()
        try? context.save()
        SupabaseSync.shared.upsertRound(round)
        // Drain the upload queue in the background so the UI doesn't
        // block on the final flush. The queue is disk-persistent, so a
        // fire-and-forget Task is safe — incomplete drain just means
        // the next round picks up the leftovers. After the drain, fold
        // this round's altitude rows into the shared height map.
        let foldInCourseId = round.courseId
        let foldInRoundId = round.id
        let skipFoldIn = round.locationTestModeEnabled == true
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
        dprint("⌚ [WatchDataStore] Ended round \(round.id) — \(reason)")
        refreshCurrentRound()
        objectWillChange.send()
    }

    /// End every still-open round. Used by startRound — once the user
    /// kicks off a new round, any prior open round is implicitly over.
    func endAnyOngoingRound(reason: String) {
        guard let context = context else { return }
        let descriptor = FetchDescriptor<Round>(
            predicate: #Predicate { $0.endedAt == nil }
        )
        let open = (try? context.fetch(descriptor)) ?? []
        let now = Date()
        for r in open {
            r.endedAt = now
            SupabaseSync.shared.upsertRound(r)
            // This path previously skipped the elevation fold-in entirely —
            // rounds auto-ended by a new round start never reached the
            // height map. Route them through the durable fold-in.
            let courseId = r.courseId
            let roundId = r.id
            if r.locationTestModeEnabled != true {
                Task { await ElevationFoldIn.run(courseId: courseId, roundId: roundId) }
            }
        }
        if !open.isEmpty {
            try? context.save()
            dprint("⌚ [WatchDataStore] Ended \(open.count) prior round(s) — \(reason)")
        }
    }

    func completeHole(holeNumber: Int) {
        guard let round = currentRound, let context = context else { return }
        var set = round.completedHoles
        set.insert(holeNumber)
        round.completedHoles = set
        try? context.save()
        SupabaseSync.shared.upsertRound(round)
        objectWillChange.send()
    }

    func reopenHole(holeNumber: Int) {
        guard let round = currentRound, let context = context else { return }
        var set = round.completedHoles
        set.remove(holeNumber)
        round.completedHoles = set
        try? context.save()
        SupabaseSync.shared.upsertRound(round)
        objectWillChange.send()
    }

    // MARK: - Hole Completion

    func finishCurrentHole() {
        guard let hole = currentHole, let round = currentRound else { return }
        completeHole(holeNumber: hole.number)
        if let next = round.hole(after: hole.number) {
            setCurrentHole(number: next.number)
        }
    }

    func isHoleCompleted(_ holeNumber: Int) -> Bool {
        currentRound?.isHoleCompleted(holeNumber) ?? false
    }

    // MARK: - Start Round (resolver-backed)


    /// Bridge between resolver completion and round start. If GolfCourseAPI
    /// returned scorecard data, present the tee picker first; otherwise start
    /// the round immediately with no tee selection.
    func handleResolved(_ resolution: RoundResolver.Resolution) {
        guard let scorecard = resolution.scorecardCourse else {
            startRound(from: resolution, selectedTeeId: nil)
            return
        }
        // Pull cached tees from DB (the Edge Function populated them as a side
        // effect of the search call during resolveScorecard).
        Task { [weak self] in
            do {
                let tees = try await GolfCourseAPIService.shared.cachedTees(
                    forExternalCourseId: String(scorecard.id)
                )
                await MainActor.run {
                    guard let self = self else { return }
                    if tees.isEmpty {
                        // Cache miss (rare — Edge Function should have written
                        // them). Skip picker, start round with no tee.
                        self.startRound(from: resolution, selectedTeeId: nil)
                    } else {
                        self.pendingTeePickerResolution = resolution
                        self.pendingTeePicker = PendingTeePicker(
                            courseName: resolution.courseName,
                            tees: tees
                        )
                    }
                }
            } catch {
                dprint("⌚ [WatchDataStore] tee fetch failed: \(error.localizedDescription) — starting without tee")
                await MainActor.run {
                    self?.startRound(from: resolution, selectedTeeId: nil)
                }
            }
        }
    }

    /// Called by the watch's tee picker UI. `nil` = user cancelled / no tee
    /// (round still starts).
    func pickTee(_ tee: CachedCourseTee?) {
        ClientEventLogger.log("pickTee.enter", detail: [
            "teeId": .string(tee?.id.uuidString ?? "nil"),
            "hasResolution": .bool(pendingTeePickerResolution != nil)
        ])
        let resolution = pendingTeePickerResolution
        pendingTeePicker = nil
        pendingTeePickerResolution = nil
        guard let resolution = resolution else { return }
        startRound(from: resolution, selectedTeeId: tee?.id)
        ClientEventLogger.log("pickTee.afterStartRound")
    }

    private func startRound(from resolution: RoundResolver.Resolution, selectedTeeId: UUID?) {
        // Tier-3 / OSM-greens-empty paths benefit from canonical-pick
        // hydration so users skip placement view for holes they've already
        // played OR for holes ≥3 users have agreed on. Pre-fetch off the
        // main thread, then create the round with coords pre-populated.
        // Tier-1 (full OSM) skips — never enters placement view.
        let needsHydration: Bool = {
            if resolution.tier == .full, let osm = resolution.osmData, !osm.greens.isEmpty {
                return false
            }
            return true
        }()
        if !needsHydration {
            performStartRound(from: resolution, selectedTeeId: selectedTeeId, canonicalPicks: [:])
            return
        }
        let courseId = resolution.courseId
        Task { [weak self] in
            guard let self = self else { return }
            let picks = await self.fetchCanonicalHolePlacements(courseId: courseId)
            await MainActor.run {
                self.canonicalHolePlacementsByCourse[courseId] = picks
                self.performStartRound(from: resolution, selectedTeeId: selectedTeeId, canonicalPicks: picks)
            }
        }
    }

    private func performStartRound(from resolution: RoundResolver.Resolution,
                                   selectedTeeId: UUID?,
                                   canonicalPicks: [Int: (lat: Double, lon: Double, par: Int?)]) {
        ClientEventLogger.log("perform.start.enter", detail: [
            "courseId": .string(resolution.courseId.uuidString),
            "tier": .string("\(resolution.tier)"),
            "selectedTeeId": selectedTeeId.map { .string($0.uuidString) } ?? .null,
            "canonicalPickCount": .integer(canonicalPicks.count)
        ])
        guard let context = context else {
            ClientEventLogger.log("perform.start.bail.noContext")
            return
        }
        // Starting a new round implies any prior open round is finished.
        endAnyOngoingRound(reason: "new round starting")
        ClientEventLogger.log("perform.start.afterEndPrior")
        if let osm = resolution.osmData {
            osmCourseDataByCourse[resolution.courseId] = osm
        }

        // Round.holes is a snapshot — built from OSM data when available,
        // otherwise a single placeholder hole the user fills in as they go.
        // For the placeholder path, consult canonicalPicks so we skip
        // HolePlacementView for hole 1 if it's resolved.
        // Hole ids come from the round id and number (`Hole.roundHoleId`).
        let roundId = UUID()
        let holes: [Hole]
        if resolution.tier == .full, let osm = resolution.osmData {
            var seen = Set<Int>()
            holes = osm.holes
                .compactMap { h -> (Int, Hole)? in
                    guard let ref = h.ref, let n = Int(ref) else { return nil }
                    let coord = CLLocationCoordinate2D(
                        latitude: h.greenPoint.latitude,
                        longitude: h.greenPoint.longitude
                    )
                    return (n, Hole(id: Hole.roundHoleId(roundId: roundId, number: n),
                                    number: n, coordinate: coord, par: h.par, teeId: selectedTeeId))
                }
                .sorted { $0.0 < $1.0 }
                .filter { seen.insert($0.0).inserted }
                .map { $0.1 }
        } else if let pick = canonicalPicks[1] {
            let coord = CLLocationCoordinate2D(latitude: pick.lat, longitude: pick.lon)
            holes = [Hole(id: Hole.roundHoleId(roundId: roundId, number: 1),
                          number: 1, coordinate: coord, par: pick.par, teeId: selectedTeeId)]
        } else {
            holes = [Hole(id: Hole.roundHoleId(roundId: roundId, number: 1), number: 1, teeId: selectedTeeId)]
        }

        // Ensure a local Course mirror of the (shared) row exists. The
        // resolver already INSERTed the shared row when isExistingCourse=false,
        // and the row already exists when true. We mirror so view code can
        // resolve names/holes against SwiftData without round-tripping.
        let lookupId = resolution.courseId
        let courseDescriptor = FetchDescriptor<Course>(
            predicate: #Predicate { $0.id == lookupId }
        )
        let existingCourse = (try? context.fetch(courseDescriptor))?.first
        let course: Course
        if let existing = existingCourse {
            existing.name = resolution.courseName
            if existing.osmId == nil { existing.osmId = resolution.osmId }
            if let ext = resolution.scorecardCourse.map({ String($0.id) }) {
                existing.externalCourseId = ext
            }
            course = existing
        } else {
            course = Course(
                id: resolution.courseId,
                name: resolution.courseName,
                holes: [],
                centerLat: resolution.courseCoordinate.latitude,
                centerLon: resolution.courseCoordinate.longitude,
                osmId: resolution.osmId,
                externalCourseId: resolution.scorecardCourse.map { String($0.id) }
            )
            context.insert(course)
        }

        ClientEventLogger.log("perform.start.afterCourseMirror", detail: [
            "holeCount": .integer(holes.count)
        ])
        let newRound = Round(
            id: roundId,
            courseId: resolution.courseId,
            courseName: resolution.courseName,
            holes: holes,
            selectedTeeId: selectedTeeId
        )
        for h in holes { context.insert(h) }
        context.insert(newRound)
        try? context.save()
        ClientEventLogger.log("perform.start.afterContextSave", detail: [
            "roundId": .string(newRound.id.uuidString)
        ])
        refreshCurrentRound()
        ClientEventLogger.log("perform.start.afterRefreshCurrentRound")
        // Only mirror our local Course edits to Supabase when the row was
        // already there (isExistingCourse=true). When isExistingCourse=false
        // AND the resolver had OSM data, the resolver itself INSERTed the
        // canonical shared row carrying all the geo + osm_polygons fields —
        // calling upsertCourse here would overwrite that with the thinner
        // local mirror.
        //
        // Exception: manual ("Course not listed") and MapKit-fallback paths
        // both have isExistingCourse=false AND osmData=nil — the resolver
        // skipped the INSERT for them. iPhone-side blob detection needs a
        // shared `courses` row to exist (it does fetchAndInsertCourse by
        // id) so we upsert a thin row here for those paths.
        if resolution.isExistingCourse {
            SupabaseSync.shared.upsertCourse(course)
        } else if resolution.osmData == nil {
            SupabaseSync.shared.upsertCourse(course)
        }
        SupabaseSync.shared.upsertRound(newRound)
        SupabaseSync.shared.upsertRoundHoles(newRound)
        ClientEventLogger.log("perform.start.afterUpsertRound")
        dprint("⌚ [WatchDataStore] Started round at \(resolution.courseName) (tier=\(resolution.tier), \(holes.count) holes, tee=\(selectedTeeId?.uuidString ?? "none"), existing=\(resolution.isExistingCourse))")

        // Path + altitude capture. Hole-number provider re-reads the live
        // round each sample so every row is tagged with the hole the user
        // is actually on at capture time, not at upload.
        if let uid = WatchAuthSession.shared.currentUserId {
            ClientEventLogger.log("perform.start.beforeStartPathRecording")
            let roundId = newRound.id
            LocationManager.shared.startPathRecording(roundId: roundId, userId: uid) { [weak self] in
                guard let self, let r = self.currentRound, r.id == roundId else { return 1 }
                return r.currentHoleNumber
            }
            ClientEventLogger.log("perform.start.afterStartPathRecording")
        } else {
            ClientEventLogger.log("altitude.recording.skipped.noUid", detail: [
                "roundId": .string(newRound.id.uuidString)
            ])
        }

        // Live elevation-to-green readout. Pre-load cells for this
        // course's holes so the readout has data to consume on the very
        // first path-sample tick.
        let elevationCourseId = newRound.courseId
        Task { @MainActor in
            await HoleHeightCellCache.shared.loadForCourse(courseId: elevationCourseId)
            ElevationReadout.shared.start(courseId: elevationCourseId)
            await HistoricalFirstStrokeCache.shared.loadForCourse(
                courseId: elevationCourseId
            )
        }

        // Hydrate per-hole yardage AND par for the selected tee. Yardage
        // drives the scorecard yardage readout on each new hole; par
        // drives the auto-skip of the par picker in HolePlacementView.
        // Wiped on round end / start of next round.
        teeHoleYardages = [:]
        teeHolePars = [:]
        if let teeId = selectedTeeId {
            Task { [weak self] in
                do {
                    let holes = try await GolfCourseAPIService.shared.cachedHoles(forTeeId: teeId)
                    let yardageMap = Dictionary(uniqueKeysWithValues: holes.compactMap { h -> (Int, Int)? in
                        guard let yds = h.yardage else { return nil }
                        return (h.holeNumber, yds)
                    })
                    let parMap = Dictionary(uniqueKeysWithValues: holes.compactMap { h -> (Int, Int)? in
                        guard let par = h.par else { return nil }
                        return (h.holeNumber, par)
                    })
                    await MainActor.run {
                        self?.teeHoleYardages = yardageMap
                        self?.teeHolePars = parMap
                    }
                } catch {
                    dprint("⌚ [WatchDataStore] cached tee holes fetch failed: \(error)")
                }
            }
        }
        // Blob detection is the fallback for courses without usable OSM
        // green data. Two cases that need it:
        //   1. No OSM data at all (course outside OSM, or relation
        //      missing entirely).
        //   2. OSM data was returned, but the relation is incomplete —
        //      no `golf=green` features tagged inside the course bounds.
        //      Wekiva GC is an example: relation + bunkers + cartpaths
        //      are mapped but not greens/tees/holes. Without falling
        //      back here, the user lands in manual placement mode with
        //      nothing on the map to work with.
        // Blob detection is needed unless OSM gave us a complete picture:
        // tier == .full (hole refs exactly 1..N) AND every hole has its
        // green polygon. Partial OSM (e.g. Sweetwater: 3 holes, 2 greens
        // for an 18-hole course) used to short-circuit blob detection
        // because `osm.greens.isEmpty` was false — but the 2 greens cover
        // 2 holes, leaving 16 with nothing. Always pull blobs as a
        // supplement when OSM isn't clean-full.
        let needsBlobDetection: Bool = {
            guard let osm = resolution.osmData else { return true }
            if osm.tier != .full { return true }
            return osm.greens.count < osm.holes.count
        }()
        if needsBlobDetection {
            let reason: String = resolution.osmData == nil
                ? "noOsmData"
                : "osmGreensEmpty"
            ClientEventLogger.log("blob.request", detail: [
                "courseId": .string(resolution.courseId.uuidString),
                "reason": .string(reason)
            ])
            // Flip the round's hole-detection flag on so the placement UI
            // (HolePlacementView) actually shows blob candidates as overlays.
            // Without this, blobs arrive at the watch but the picker filters
            // them out — round.holeDetectionEnabled defaults to false.
            if let round = currentRound, round.holeDetectionEnabled != true {
                round.holeDetectionEnabled = true
                try? context.save()
                SupabaseSync.shared.upsertRound(round)
                ClientEventLogger.log("blob.request.holeDetectionEnabled", detail: [
                    "roundId": .string(round.id.uuidString)
                ])
                objectWillChange.send()
            }
            let courseId = resolution.courseId
            // Server-cache direct fetch. The iPhone is only needed when no
            // cached results exist and the analyzer has to run — analyzer is
            // iPhone-only. On a miss, ask the phone and hold the user on the
            // round-start card, which follows the phone's reported state
            // (`handlePhoneBlobStatus`) until Continue or the results land.
            Task { @MainActor in
                if let cached = await self.fetchServerCachedBlobs(courseId: courseId) {
                    self.applyBlobDetectionResults(cached, courseId: courseId)
                    ClientEventLogger.log("blob.serverCache.hit", detail: [
                        "courseId": .string(courseId.uuidString),
                        "blobCount": .integer(cached.blobs.count),
                        "device": .string("watch")
                    ])
                    return
                }
                ClientEventLogger.log("blob.serverCache.miss", detail: [
                    "courseId": .string(courseId.uuidString),
                    "device": .string("watch")
                ])
                self.requestBlobsFromPhone(courseId: courseId, promptUser: true)
            }
        }
    }

    /// Start a round with no GPS fix at all. The user still names the course,
    /// but with no coordinate there's nothing to anchor it to, so it can't be
    /// matched by proximity next time — it'll be re-named on the next visit.
    ///
    /// This used to create `Round(courseId: UUID(), courseName: "Quick Start")`
    /// with NO Course row anywhere, which is why those rounds ended up
    /// orphaned in Supabase pointing at a course id that never existed.
    func startManualQuickRound() {
        pendingCourseNameCompletion = { [weak self] entered in
            guard let self = self, let context = self.context else { return }
            let name = (entered ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }   // cancelled — no round

            let course = Course(name: name)
            context.insert(course)
            let roundId = UUID()
            let firstHole = Hole(id: Hole.roundHoleId(roundId: roundId, number: 1), number: 1)
            let newRound = Round(id: roundId, courseId: course.id, courseName: name, holes: [firstHole])
            context.insert(firstHole)
            context.insert(newRound)
            try? context.save()
            self.refreshCurrentRound()
            SupabaseSync.shared.upsertCourse(course)
            SupabaseSync.shared.upsertRound(newRound)
            SupabaseSync.shared.upsertRoundHoles(newRound)
        }
        pendingCourseNamePrompt = true
    }

    func startQuickRound() { startRoundAtCurrentLocation() }
}
