import Foundation
import CoreLocation
import SwiftData
import UIKit

// The satellite green detector on the phone: runs it for a course (its own
// rounds, or a request from the watch), caches its results on disk and on the
// server, and reports progress to the watch.
extension DataStore {

    func setupWatchConnectivity() {
        // Round/Stroke sync moved to DB (Realtime + SwiftData). WC only retains
        // hole detection data + hole filter settings paths now.
        // Phone is authority for filter settings — push current value to
        // watch on every WC session activation so the watch picks up the
        // latest after a launch / reconnect. The phone's GreenFiltersView
        // also pushes on each individual change for live updates.
        WatchConnectivityManager.shared.onSessionActivated = { [weak self] in
            guard let self = self else { return }
            WatchConnectivityManager.shared.sendHoleFilterSettings(self.holeFilterSettings)
        }

        // Watch-driven blob detection request. Watch hits this whenever it
        // starts/resumes a round on a course; iPhone runs the analyzer (or
        // returns cached data) and ships results back via the existing
        // sendHoleDetectionData flow. Lets the watch always have blob data
        // for visual comparison against OSM polygons, even when the iOS
        // user never explicitly opted into hole detection.
        WatchConnectivityManager.shared.onReceiveHoleDetectionRequest = { [weak self] courseId in
            guard let self = self else { return }
            Task { @MainActor in
                // Try cache → SwiftData → Supabase fetch-by-id. The third
                // step is the new one: when the round was resolved on the
                // watch (shared courses table), the iPhone may not have
                // received the Realtime INSERT echo yet, so the local
                // SwiftData has no matching row. We fetch directly from
                // Supabase and insert it before kicking off blob detection.
                var course: Course? = self.courses.first(where: { $0.id == courseId })
                if course == nil, let context = self.context {
                    let descriptor = FetchDescriptor<Course>(predicate: #Predicate { $0.id == courseId })
                    course = (try? context.fetch(descriptor))?.first
                }
                if course == nil {
                    course = await self.fetchAndInsertCourse(by: courseId)
                }
                ClientEventLogger.log("blob.request.received", detail: [
                    "courseId": .string(courseId.uuidString),
                    "courseFound": .bool(course != nil),
                    "courseName": course.map { .string($0.name) } ?? .null
                ])
                guard course != nil else {
                    WatchConnectivityManager.shared.sendHoleDetectionStatus(courseId: courseId, state: .failed)
                    return
                }
                self.enqueueWatchHoleDetection(courseId)
            }
        }

        // Clubs/types now sync via DB — both devices read from SwiftData and
        // observe Realtime changes; no WC push needed at startup.
    }

    /// Server-side blob-detection cache fetch. Returns nil on miss /
    /// network error / decode error so the caller falls back to the
    /// analyzer.
    @MainActor
    private func fetchBlobDetectionResults(courseId: UUID) async -> CourseHoleDetectionData? {
        struct Row: Decodable {
            let blob_detection_results: CourseHoleDetectionData?
        }
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

    /// Server-side blob-detection cache write, through
    /// `store_course_blob_detection` (migration 00056), which returns the
    /// results in force. On a shared course the first stored set stands, since
    /// every device and user picks greens from it (pick votes compare its blob
    /// ids); when another device's run landed first, this device adopts that
    /// set and sends it to the watch in place of its own. Fire-and-forget;
    /// failures are non-fatal — the in-memory + JSON cache still works.
    private func uploadBlobDetectionResults(courseId: UUID, data: CourseHoleDetectionData) {
        struct Params: Encodable {
            let p_course_id: String
            let p_results: CourseHoleDetectionData
        }
        let params = Params(p_course_id: courseId.uuidString, p_results: data)
        Task { @MainActor in
            do {
                let inForce: CourseHoleDetectionData? = try await SupabaseManager.shared.client
                    .rpc("store_course_blob_detection", params: params)
                    .execute()
                    .value
                if let inForce {
                    if inForce.blobs.map(\.id) != data.blobs.map(\.id) {
                        self.holeDetectionDataByCourse[courseId] = inForce
                        self.saveHoleDetectionData()
                        WatchConnectivityManager.shared.sendHoleDetectionData(inForce)
                        ClientEventLogger.log("blob.serverCache.adoptedStored", detail: [
                            "courseId": .string(courseId.uuidString),
                            "blobCount": .integer(inForce.blobs.count)
                        ])
                    } else {
                        ClientEventLogger.log("blob.serverCache.uploaded", detail: [
                            "courseId": .string(courseId.uuidString),
                            "blobCount": .integer(data.blobs.count)
                        ])
                    }
                } else {
                    ClientEventLogger.log("blob.serverCache.uploadError", detail: [
                        "courseId": .string(courseId.uuidString),
                        "error": .string("course not visible to this user")
                    ])
                }
            } catch {
                ClientEventLogger.log("blob.serverCache.uploadError", detail: [
                    "courseId": .string(courseId.uuidString),
                    "error": .string("\(error)")
                ])
            }
            // `done` tells the watch to read the server cache, so it goes out
            // only once the write has landed (or failed — the WC data push
            // still carries the blobs then).
            self.finishHoleDetection(courseId: courseId, state: .done)
        }
    }

    /// Public entry point so watch-initiated hole detection requests can
    /// kick off the same pipeline. Cached results return immediately;
    /// otherwise the analyzer runs and ships results back via WC when done.
    func runHoleDetection(for course: Course) {
        startHoleDetection(for: course, allowCache: true, persistResult: true)
    }

    // MARK: - Watch-requested analysis queue

    /// Courses the watch asked to analyze that have not finished yet.
    ///
    /// A watch request usually arrives with this app in the background —
    /// WatchConnectivity launches it there to deliver the message — and the
    /// analyzer's MapKit snapshots do not complete for a backgrounded app. On
    /// 2026-09-07 the Blue Sky request started that way, died without logging
    /// anything, and the course never got blobs. So a request only ever runs
    /// while the app is on screen; otherwise it waits here and the watch is
    /// told `queued`. Persisted, so a request survives the app being killed.
    private var watchHoleDetectionQueue: [UUID] {
        get {
            (UserDefaults.standard.stringArray(forKey: watchHoleDetectionQueueKey) ?? [])
                .compactMap(UUID.init(uuidString:))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.uuidString), forKey: watchHoleDetectionQueueKey)
        }
    }

    private func enqueueWatchHoleDetection(_ courseId: UUID) {
        if !watchHoleDetectionQueue.contains(courseId) {
            watchHoleDetectionQueue.append(courseId)
        }
        drainWatchHoleDetectionQueue()
    }

    /// Run every queued watch request, if the app is on screen. Called when a
    /// request arrives and on every foreground.
    func drainWatchHoleDetectionQueue() {
        let queue = watchHoleDetectionQueue
        guard !queue.isEmpty, let context = context else { return }
        let appState = UIApplication.shared.applicationState
        guard appState == .active else {
            for courseId in queue {
                WatchConnectivityManager.shared.sendHoleDetectionStatus(courseId: courseId, state: .queued)
            }
            ClientEventLogger.log("blob.request.queued", detail: [
                "courseIds": .string(queue.map(\.uuidString).joined(separator: ",")),
                "appState": .string(appState == .background ? "background" : "inactive")
            ])
            return
        }
        for courseId in queue {
            let course = courses.first(where: { $0.id == courseId })
                ?? (try? context.fetch(FetchDescriptor<Course>(predicate: #Predicate { $0.id == courseId })))?.first
            guard let course else {
                ClientEventLogger.log("blob.analyzer.courseMissing", detail: [
                    "courseId": .string(courseId.uuidString)
                ])
                finishHoleDetection(courseId: courseId, state: .failed)
                continue
            }
            startHoleDetection(for: course, allowCache: true, persistResult: true)
        }
    }

    /// The single exit of every analysis run: tell the watch where it ended,
    /// drop the course from the queue, release the background task.
    private func finishHoleDetection(courseId: UUID, state: HoleDetectionPhoneState) {
        watchHoleDetectionQueue.removeAll { $0 == courseId }
        WatchConnectivityManager.shared.sendHoleDetectionStatus(courseId: courseId, state: state)
        if let task = holeDetectionBackgroundTasks.removeValue(forKey: courseId) {
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    /// Domain, code and message — enough to tell a MapKit throttle from a
    /// render failure from a timeout in `client_events`.
    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain)#\(ns.code): \(ns.localizedDescription)"
    }

    private var holeDetectionFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(holeDetectionFileName)
    }

    func loadHoleDetectionData() {
        guard FileManager.default.fileExists(atPath: holeDetectionFileURL.path) else { return }

        do {
            let data = try Data(contentsOf: holeDetectionFileURL)
            let detections = try JSONDecoder().decode([CourseHoleDetectionData].self, from: data)
            holeDetectionDataByCourse = Dictionary(uniqueKeysWithValues: detections.map { ($0.courseId, $0) })
        } catch {
            dprint("📱 [DataStore] Failed to load hole detection data: \(error.localizedDescription)")
        }
    }

    func saveHoleDetectionData() {
        do {
            let detections = Array(holeDetectionDataByCourse.values)
            let data = try JSONEncoder().encode(detections)
            try data.write(to: holeDetectionFileURL)
        } catch {
            dprint("📱 [DataStore] Failed to save hole detection data: \(error.localizedDescription)")
        }
    }

    func loadHoleFilterSettings() {
        guard let data = UserDefaults.standard.data(forKey: holeFilterSettingsKey),
              let settings = try? JSONDecoder().decode(HoleDetectionFilterSettings.self, from: data) else {
            holeFilterSettings = .default
            return
        }
        holeFilterSettings = settings
    }

    func saveHoleFilterSettings() {
        guard let data = try? JSONEncoder().encode(holeFilterSettings) else { return }
        UserDefaults.standard.set(data, forKey: holeFilterSettingsKey)
    }

    func holeDetectionStatus(for courseId: UUID) -> HoleDetectionRunState? {
        holeDetectionRunStateByCourse[courseId]
    }

    func filteredHoleDetectionBlobs(for courseId: UUID) -> [HoleDetectionBlob] {
        guard let data = holeDetectionDataByCourse[courseId] else { return [] }
        return holeFilterSettings.apply(to: data.blobs)
    }

    func startHoleDetection(
        for course: Course,
        overrideCenter: CLLocationCoordinate2D? = nil,
        allowCache: Bool = true,
        persistResult: Bool = true
    ) {
        if holeDetectionRunStateByCourse[course.id]?.isRunning == true {
            // A re-request mid-run still gets an answer.
            WatchConnectivityManager.shared.sendHoleDetectionStatus(courseId: course.id, state: .running)
            return
        }

        if allowCache, let cached = holeDetectionDataByCourse[course.id] {
            dprint("📱 [DataStore] Using cached hole detection data (\(cached.blobs.count) blobs)")
            holeDetectionRunStateByCourse[course.id] = HoleDetectionRunState(
                isRunning: false,
                message: "Hole detection ready",
                progress: 1.0,
                error: nil
            )
            WatchConnectivityManager.shared.sendHoleDetectionData(cached)
            finishHoleDetection(courseId: course.id, state: .done)
            return
        }

        // Server-side cache: courses.blob_detection_results. If a previous
        // run (any device, any user) already analyzed this course, fetch
        // and reuse instead of running the analyzer locally. The fetch is
        // async; on miss we re-call ourselves with allowCache=false so the
        // analyzer code path runs synchronously. On hit we ship and return.
        if allowCache {
            let courseId = course.id
            let overrideCenterLocal = overrideCenter
            Task { @MainActor in
                if let serverCached = await self.fetchBlobDetectionResults(courseId: courseId) {
                    self.holeDetectionDataByCourse[courseId] = serverCached
                    self.saveHoleDetectionData()
                    self.holeDetectionRunStateByCourse[courseId] = HoleDetectionRunState(
                        isRunning: false,
                        message: "Hole detection ready (cached)",
                        progress: 1.0,
                        error: nil
                    )
                    WatchConnectivityManager.shared.sendHoleDetectionData(serverCached)
                    ClientEventLogger.log("blob.serverCache.hit", detail: [
                        "courseId": .string(courseId.uuidString),
                        "blobCount": .integer(serverCached.blobs.count)
                    ])
                    self.finishHoleDetection(courseId: courseId, state: .done)
                } else {
                    ClientEventLogger.log("blob.serverCache.miss", detail: [
                        "courseId": .string(courseId.uuidString)
                    ])
                    self.startHoleDetection(
                        for: course,
                        overrideCenter: overrideCenterLocal,
                        allowCache: false,
                        persistResult: persistResult
                    )
                }
            }
            return
        }

        // The course's own stored center comes before this phone's GPS. A
        // queued watch request can run hours after it was made, wherever the
        // phone happens to be when the app is next opened, and centering on
        // the phone then scans the wrong place entirely. Placed holes still
        // win — they are where the greens actually are.
        let storedCenter: CLLocationCoordinate2D? = {
            guard let lat = course.centerLat, let lon = course.centerLon else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }()
        let resolvedCenter: (coordinate: CLLocationCoordinate2D, source: String)? = {
            if let c = overrideCenter { return (c, "override") }
            if let c = calculateCourseCentroid(course: course) { return (c, "holes") }
            if let c = storedCenter { return (c, "courseRecord") }
            if let c = LocationManager.shared.getCurrentLocation()?.coordinate { return (c, "phoneGPS") }
            return nil
        }()
        guard let resolvedCenter else {
            holeDetectionRunStateByCourse[course.id] = HoleDetectionRunState(
                isRunning: false,
                message: "Hole detection unavailable",
                progress: 0,
                error: "No location available"
            )
            ClientEventLogger.log("blob.analyzer.noCenter", detail: [
                "courseId": .string(course.id.uuidString)
            ])
            finishHoleDetection(courseId: course.id, state: .failed)
            return
        }
        let center = resolvedCenter.coordinate

        let coverageRadius = holeDetectionCoverageRadius(for: course, center: center)
        // Decode the OSM bounding polygon(s) if we have them — used to gate
        // blob detection so two courses on the same property (Stonegate
        // Cypress vs Oaks) don't cross-contaminate. Old courses rows
        // without `boundingPolygons` (pre-fix) decode to nil and the
        // analyzer falls back to the radius-only behavior.
        let boundingPolygons: [[CLLocationCoordinate2D]]? = {
            guard let data = course.osmPolygons,
                  let osm = try? JSONDecoder().decode(OSMCourseData.self, from: data),
                  let polys = osm.boundingPolygons, !polys.isEmpty else { return nil }
            return polys.map { $0.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } }
        }()
        holeDetectionRunStateByCourse[course.id] = HoleDetectionRunState(
            isRunning: true,
            message: "Starting hole detection...",
            progress: 0,
            error: nil
        )
        let courseIdForTask = course.id
        holeDetectionBackgroundTasks[course.id] = UIApplication.shared.beginBackgroundTask(withName: "holeDetection") { [weak self] in
            // Out of background time before the run finished. The analyzer
            // cannot be cancelled, so its completion still fires later; this
            // only returns the task so the app is not terminated for holding it.
            guard let self, let task = self.holeDetectionBackgroundTasks.removeValue(forKey: courseIdForTask) else { return }
            ClientEventLogger.log("blob.analyzer.backgroundExpired", detail: [
                "courseId": .string(courseIdForTask.uuidString)
            ])
            UIApplication.shared.endBackgroundTask(task)
        }
        WatchConnectivityManager.shared.sendHoleDetectionStatus(courseId: course.id, state: .running)
        ClientEventLogger.log("blob.analyzer.started", detail: [
            "courseId": .string(course.id.uuidString),
            "centerSource": .string(resolvedCenter.source),
            "coverageRadiusMeters": .double(coverageRadius)
        ])

        // The model object stays on main; the callbacks only need its id.
        let detectedCourseId = course.id
        holeDetectionAnalyzer.detect(
            courseId: detectedCourseId,
            center: center,
            coverageRadiusMeters: coverageRadius,
            boundingPolygons: boundingPolygons,
            progress: { [weak self] message, progress in
                DispatchQueue.main.async {
                    self?.holeDetectionRunStateByCourse[detectedCourseId] = HoleDetectionRunState(
                        isRunning: true,
                        message: message,
                        progress: progress,
                        error: nil
                    )
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .success(let output):
                        let detectionData = output.data
                        dprint("📱 [DataStore] Hole detection diagnostics: tiles=\(output.diagnostics.tileCount), greenPx=\(output.diagnostics.totalGreenPixels), greenishPx=\(output.diagnostics.totalGreenishPixels), swappedExactPx=\(output.diagnostics.totalSwappedChannelExactPixels), preMergeBlobs=\(output.diagnostics.preMergeBlobCount), mergedBlobs=\(output.diagnostics.mergedBlobCount)")
                        if output.diagnostics.topGreenishColors.isEmpty {
                            dprint("📱 [DataStore] Hole detection top green-ish RGBs: none above threshold")
                        } else {
                            let colors = output.diagnostics.topGreenishColors.map(\.formatted).joined(separator: " | ")
                            dprint("📱 [DataStore] Hole detection top green-ish RGBs: \(colors)")
                        }
                        // Keep detection results in memory for current-round UI even when test runs are non-persistent.
                        self.holeDetectionDataByCourse[detectedCourseId] = detectionData
                        if persistResult {
                            self.saveHoleDetectionData()
                            // Server-side persistence — write to courses
                            // table so any device picking up this round
                            // (or another user playing the same course)
                            // skips the analyzer.
                            self.uploadBlobDetectionResults(courseId: detectedCourseId, data: detectionData)
                        }
                        self.holeDetectionRunStateByCourse[detectedCourseId] = HoleDetectionRunState(
                            isRunning: false,
                            message: output.diagnostics.summaryMessage,
                            progress: 1.0,
                            error: nil
                        )
                        WatchConnectivityManager.shared.sendHoleDetectionData(detectionData)
                        ClientEventLogger.log("blob.analyzer.succeeded", detail: [
                            "courseId": .string(detectedCourseId.uuidString),
                            "tileCount": .integer(output.diagnostics.tileCount),
                            "blobCount": .integer(detectionData.blobs.count)
                        ])
                        // Persisted runs report `done` from the upload, once
                        // the server cache actually holds the result.
                        if !persistResult {
                            self.finishHoleDetection(courseId: detectedCourseId, state: .done)
                        }
                    case .failure(let error):
                        self.holeDetectionRunStateByCourse[detectedCourseId] = HoleDetectionRunState(
                            isRunning: false,
                            message: "Hole detection failed",
                            progress: 0,
                            error: error.localizedDescription
                        )
                        let tileErrors = (error as? HoleDetectionAllTilesFailed)?.errors ?? [error]
                        ClientEventLogger.log("blob.analyzer.failed", detail: [
                            "courseId": .string(detectedCourseId.uuidString),
                            "tileErrorCount": .integer(tileErrors.count),
                            "errors": .string(Set(tileErrors.map(Self.describe)).sorted().joined(separator: " | "))
                        ])
                        self.finishHoleDetection(courseId: detectedCourseId, state: .failed)
                    }
                }
            }
        )
    }

    private func holeDetectionCoverageRadius(for course: Course, center: CLLocationCoordinate2D) -> Double {
        let coords = course.holes.compactMap { $0.coordinate }
        guard !coords.isEmpty else {
            return 2800
        }

        let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let maxDistance = coords.map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: centerLocation)
        }.max() ?? 0

        return max(1800, maxDistance + 800)
    }

    private func calculateCourseCentroid(course: Course) -> CLLocationCoordinate2D? {
        let holesWithCoords = course.holes.compactMap { $0.coordinate }
        guard !holesWithCoords.isEmpty else { return nil }
        let avgLat = holesWithCoords.map { $0.latitude }.reduce(0, +) / Double(holesWithCoords.count)
        let avgLon = holesWithCoords.map { $0.longitude }.reduce(0, +) / Double(holesWithCoords.count)
        return CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
    }
}
