import Foundation
import SwiftData

// Green geometry for the watch: blob-detection results (server cache first,
// then a request to the phone), cross-user hole placements, and the course's
// OSM data.
extension WatchDataStore {

    func hydrateBlobDetectionForCourse(_ courseId: UUID) {
        Task { [weak self] in
            guard let self = self else { return }
            if let cached = await self.fetchServerCachedBlobs(courseId: courseId) {
                await MainActor.run {
                    self.applyBlobDetectionResults(cached, courseId: courseId)
                    ClientEventLogger.log("blob.serverCache.hit", detail: [
                        "courseId": .string(courseId.uuidString),
                        "blobCount": .integer(cached.blobs.count),
                        "device": .string("watch"),
                        "trigger": .string("resumeRound")
                    ])
                }
            } else {
                ClientEventLogger.log("blob.serverCache.miss", detail: [
                    "courseId": .string(courseId.uuidString),
                    "device": .string("watch"),
                    "trigger": .string("resumeRound")
                ])
                // The phone may never have run it (killed, or never opened
                // since the round started). Ask again — it queues until its
                // app is on screen. Once per app session: this path runs on
                // every round refresh while the blobs are missing.
                await MainActor.run {
                    guard self.currentRound?.courseId == courseId,
                          self.currentRound?.holeDetectionEnabled == true,
                          self.blobRequestStatusByCourse[courseId] == nil else { return }
                    self.requestBlobsFromPhone(courseId: courseId, promptUser: false)
                }
            }
        }
    }

    /// Ask the iPhone to analyze a course. `promptUser` puts up the
    /// round-start card, which then tracks the phone's reported state.
    func requestBlobsFromPhone(courseId: UUID, promptUser: Bool) {
        blobRequestStatusByCourse[courseId] = .sent
        if promptUser { blobPromptCourseId = courseId }
        WatchConnectivityManager.shared.sendHoleDetectionRequest(courseId: courseId) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self,
                      self.holeDetectionDataByCourse[courseId] == nil else { return }
                self.blobRequestStatusByCourse[courseId] = .unreachable
                ClientEventLogger.log("blob.request.undeliverable", detail: [
                    "courseId": .string(courseId.uuidString)
                ])
            }
        }
    }

    /// Continue on the round-start card: proceed without blobs. Whatever the
    /// phone produces later still applies through `applyBlobDetectionResults`.
    func continueWithoutBlobs() {
        guard let courseId = blobPromptCourseId else { return }
        ClientEventLogger.log("blob.prompt.continued", detail: [
            "courseId": .string(courseId.uuidString),
            "status": .string(blobRequestStatusByCourse[courseId].map { "\($0)" } ?? "none")
        ])
        blobPromptCourseId = nil
    }

    func handlePhoneBlobStatus(courseId: UUID, state: HoleDetectionPhoneState) {
        ClientEventLogger.log("blob.phoneStatus", detail: [
            "courseId": .string(courseId.uuidString),
            "state": .string(state.rawValue)
        ])
        guard holeDetectionDataByCourse[courseId] == nil else { return }
        switch state {
        case .queued:  blobRequestStatusByCourse[courseId] = .queued
        case .running: blobRequestStatusByCourse[courseId] = .running
        case .failed:  blobRequestStatusByCourse[courseId] = .failed
        case .done:
            // The server cache is the fast path; the WC data push is a file
            // transfer above 50KB and can take minutes. If the upload failed,
            // that push is still coming and applies on arrival.
            Task { @MainActor in
                if let cached = await self.fetchServerCachedBlobs(courseId: courseId) {
                    self.applyBlobDetectionResults(cached, courseId: courseId)
                    ClientEventLogger.log("blob.serverCache.hit", detail: [
                        "courseId": .string(courseId.uuidString),
                        "blobCount": .integer(cached.blobs.count),
                        "device": .string("watch"),
                        "trigger": .string("phoneDone")
                    ])
                }
            }
        }
    }

    /// Store arrived blob results and unstick the placement UI. Single
    /// funnel for every delivery path (up-front cache hit, pending-window
    /// poll, WC receive, resume hydrate) so they all also re-assert the
    /// round's `holeDetectionEnabled` flag.
    func applyBlobDetectionResults(_ data: CourseHoleDetectionData, courseId: UUID) {
        holeDetectionDataByCourse[courseId] = data
        blobRequestStatusByCourse[courseId] = nil
        if blobPromptCourseId == courseId { blobPromptCourseId = nil }
        ensureHoleDetectionEnabled(forCourse: courseId)
    }

    /// Re-assert `holeDetectionEnabled` on the current round when blob data
    /// is applied for its course. The flag is flipped on at blob-request
    /// time, but a cross-device round upsert can clobber it back to false —
    /// the iPhone's reconcile races the watch's flip (seen live at Wolf
    /// Hollow 2026-07-05: the round row carried false 36s after the watch
    /// wrote true). The picker gate (AddHoleNavigationView) returns zero
    /// candidates while the flag is off, so without this heal, blobs arrive
    /// and stay invisible. Re-writing at data-apply time converges every
    /// clobber source: our upsert carries true and realtime propagates it
    /// back to the other device.
    func ensureHoleDetectionEnabled(forCourse courseId: UUID) {
        guard let round = currentRound,
              round.courseId == courseId,
              round.holeDetectionEnabled != true else { return }
        round.holeDetectionEnabled = true
        try? context?.save()
        SupabaseSync.shared.upsertRound(round)
        ClientEventLogger.log("blob.holeDetectionEnabled.healed", detail: [
            "roundId": .string(round.id.uuidString)
        ])
        objectWillChange.send()
    }

    private struct PickRow: Decodable {
        let user_id: UUID
        let hole_number: Int
        let blob_id: UUID?
        let latitude: Double?
        let longitude: Double?
        let par: Int?
    }

    func fetchCanonicalHolePlacements(courseId: UUID) async -> [Int: (lat: Double, lon: Double, par: Int?)] {
        let myUserId = WatchAuthSession.shared.currentUserId.flatMap(UUID.init(uuidString:))
        let blobs = await fetchServerCachedBlobs(courseId: courseId)
        let blobsById: [UUID: HoleDetectionBlob] = Dictionary(uniqueKeysWithValues: (blobs?.blobs ?? []).map { ($0.id, $0) })
        let picks: [PickRow]
        do {
            picks = try await SupabaseManager.shared
                .from("course_hole_picks")
                .select("user_id,hole_number,blob_id,latitude,longitude,par")
                .eq("course_id", value: courseId.uuidString)
                .execute()
                .value
        } catch {
            ClientEventLogger.log("canonicalPlacements.fetchError", detail: [
                "courseId": .string(courseId.uuidString),
                "error": .string("\(error)")
            ])
            return [:]
        }
        let byHole = Dictionary(grouping: picks, by: { $0.hole_number })
        var result: [Int: (lat: Double, lon: Double, par: Int?)] = [:]
        for (hole, rows) in byHole {
            // Rule 1: this user has a pick
            if let mine = rows.first(where: { $0.user_id == myUserId }) {
                if let bid = mine.blob_id, let blob = blobsById[bid] {
                    let c = blob.centroidCoordinate
                    result[hole] = (c.latitude, c.longitude, mine.par)
                } else if let lat = mine.latitude, let lon = mine.longitude {
                    result[hole] = (lat, lon, mine.par)
                }
                continue
            }
            // Rule 2: voting on blob_id (manual picks excluded)
            let blobPicks = rows.compactMap { $0.blob_id }
            let distinctVoters = Set(rows.compactMap { $0.blob_id != nil ? $0.user_id : nil }).count
            guard distinctVoters >= 3 else { continue }
            let counts = Dictionary(grouping: blobPicks, by: { $0 }).mapValues { $0.count }
            guard let (modalBlob, modalCount) = counts.max(by: { $0.value < $1.value }) else { continue }
            let share = Double(modalCount) / Double(distinctVoters)
            guard share >= 0.75 else { continue }
            guard let blob = blobsById[modalBlob] else { continue }
            // Modal par among the agreeing voters
            let agreeingPars = rows.filter { $0.blob_id == modalBlob }.compactMap { $0.par }
            let parCounts = Dictionary(grouping: agreeingPars, by: { $0 }).mapValues { $0.count }
            let modalPar = parCounts.max(by: { $0.value < $1.value })?.key
            let c = blob.centroidCoordinate
            result[hole] = (c.latitude, c.longitude, modalPar)
        }
        ClientEventLogger.log("canonicalPlacements.fetched", detail: [
            "courseId": .string(courseId.uuidString),
            "holeCount": .integer(result.count),
            "pickRowCount": .integer(picks.count)
        ])
        return result
    }

    /// Direct PostgREST read of `courses.blob_detection_results`. Mirrors
    /// the iPhone's `DataStore.fetchBlobDetectionResults`. Watch reads the
    /// cache itself rather than asking the iPhone over WC, so blob overlays
    /// work even when the iPhone is asleep / out of range.
    func fetchServerCachedBlobs(courseId: UUID) async -> CourseHoleDetectionData? {
        struct Row: Decodable { let blob_detection_results: CourseHoleDetectionData? }
        do {
            let rows: [Row] = try await SupabaseManager.shared
                .from("courses")
                .select("blob_detection_results")
                .eq("id", value: courseId.uuidString)
                .limit(1)
                .execute()
                .value
            return rows.first?.blob_detection_results
        } catch {
            ClientEventLogger.log("blob.serverCache.fetchError", detail: [
                "courseId": .string(courseId.uuidString),
                "error": .string("\(error)")
            ])
            return nil
        }
    }

    /// Called from `refreshCurrentRound` whenever a round becomes current
    /// without having gone through the resolver this session.

    /// Fire-and-forget fetch of `courses.osm_polygons` for the given course
    /// id; on success, populates `osmCourseDataByCourse[courseId]`.
    func hydrateOsmDataForCourse(_ courseId: UUID) {
        struct Row: Decodable { let osm_polygons: OSMCourseData? }
        ClientEventLogger.log("greenHydrate.start", detail: [
            "courseId": .string(courseId.uuidString)
        ])
        Task { [weak self] in
            do {
                let rows: [Row] = try await SupabaseManager.shared
                    .from("courses")
                    .select("osm_polygons")
                    .eq("id", value: courseId.uuidString)
                    .limit(1)
                    .execute()
                    .value
                let osm = rows.first?.osm_polygons
                ClientEventLogger.log("greenHydrate.fetched", detail: [
                    "rowCount": .integer(rows.count),
                    "hasOsm": .bool(osm != nil),
                    "greenCount": .integer(osm?.greens.count ?? 0),
                    "holeCount": .integer(osm?.holes.count ?? 0)
                ])
                guard let osm = osm else { return }
                await MainActor.run {
                    self?.osmCourseDataByCourse[courseId] = osm
                }
            } catch {
                ClientEventLogger.log("greenHydrate.failed", detail: [
                    "error": .string("\(error)")
                ])
            }
        }
    }

    func osmCourseData(forCourseId id: UUID) -> OSMCourseData? {
        osmCourseDataByCourse[id]
    }

    /// Refresh `myPlayerColor` from the user's current playgroup membership.
    /// Call this after host/join operations. If the user isn't in a playgroup,
    /// falls back to palette[0] so the GPS arrow stays a familiar color.
}
