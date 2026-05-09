import Foundation
import WatchConnectivity

/// Now demoted: Round/Stroke/Club sync moves to the database (via Supabase
/// Realtime + SwiftData local cache). The remaining responsibilities of this
/// manager are the things that genuinely need a direct phone↔watch channel
/// because they don't live in the relational DB:
///   - **Auth session push** (iPhone → Watch): the SDK auth refresh is the
///     watch's source for tokens, but the initial Sign In With Apple flow
///     can only happen on the phone. The watch listens for application-context
///     updates and feeds them into its own SDK session.
///   - **Hole detection data** (iPhone → Watch): blob detection runs on the
///     phone (MapKit snapshot APIs aren't on watchOS); results push to the
///     watch for Tier-3 round play.
///
/// Motion CSV / swing log file transfers used to flow through here too.
/// They're gone — swing data goes directly from the watch to Supabase
/// (`swing_events` + `false_negative_groups`), so the phone is no longer
/// in the loop for any motion artifact.
class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()

    @Published var isReachable = false
    @Published var isActivated = false

    // Callbacks for received data
    var onReceiveHoleDetectionData: ((CourseHoleDetectionData) -> Void)?
    var onReceiveHoleFilterSettings: ((HoleDetectionFilterSettings) -> Void)?
    /// Watch asks iPhone to run hole detection for a course id. iPhone-only
    /// callback; consumed by `DataStore` which kicks off `startHoleDetection`.
    var onReceiveHoleDetectionRequest: ((UUID) -> Void)?
    /// Fires once activation completes (success path). Currently used by
    /// iOS DataStore to push the authoritative hole-filter settings down
    /// to the watch on each (re)activation.
    var onSessionActivated: (() -> Void)?

    // Pending sends queued until the WC session is activated.
    private var pendingHoleDetectionData: CourseHoleDetectionData?
    private var pendingHoleFilterSettings: HoleDetectionFilterSettings?

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    // MARK: - Hole detection data (iPhone → Watch)

    /// Send raw hole-detection blobs for a course (iPhone → Watch). Stays on
    /// WC because the blob payload is large and ephemeral; not worth a DB
    /// roundtrip for what the watch needs immediately.
    func sendHoleDetectionData(_ data: CourseHoleDetectionData) {
        dprint("📱 [iPhone] sendHoleDetectionData for course \(data.courseId), blobs: \(data.blobs.count)")
        guard WCSession.default.activationState == .activated else {
            pendingHoleDetectionData = data
            return
        }
        actuallySendHoleDetectionData(data)
    }

    private func actuallySendHoleDetectionData(_ detectionData: CourseHoleDetectionData) {
        do {
            let encoded = try JSONEncoder().encode(detectionData)
            let shouldUseFileTransfer: Bool = {
#if targetEnvironment(simulator)
                return false
#else
                return encoded.count > 50_000
#endif
            }()
            if shouldUseFileTransfer {
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hole_detection_\(detectionData.courseId.uuidString).json")
                try encoded.write(to: tempURL)
                WCSession.default.transferFile(tempURL, metadata: ["type": "holeDetectionData"])
                return
            }
            if WCSession.default.isReachable {
                let message: [String: Any] = ["type": "holeDetectionData", "data": encoded]
                WCSession.default.sendMessage(message, replyHandler: nil) { error in
                    dprint("📱 [iPhone] Failed to send hole detection data: \(error.localizedDescription)")
                    self.updateHoleDetectionContext(encoded)
                }
            } else {
                updateHoleDetectionContext(encoded)
            }
        } catch {
            dprint("📱 [iPhone] Failed to encode hole detection data: \(error)")
        }
    }

    // MARK: - Hole filter settings (Watch → iPhone, Watch is authority)

    func sendHoleFilterSettings(_ settings: HoleDetectionFilterSettings) {
        guard WCSession.default.activationState == .activated else {
            pendingHoleFilterSettings = settings
            return
        }
        actuallySendHoleFilterSettings(settings)
    }

    private func actuallySendHoleFilterSettings(_ settings: HoleDetectionFilterSettings) {
        do {
            let encoded = try JSONEncoder().encode(settings)
            if WCSession.default.isReachable {
                let message: [String: Any] = ["type": "holeFilterSettings", "data": encoded]
                WCSession.default.sendMessage(message, replyHandler: nil) { error in
                    dprint("⌚ [Watch] Failed to send hole filter settings: \(error.localizedDescription)")
                    self.updateHoleFilterSettingsContext(encoded)
                }
            } else {
                updateHoleFilterSettingsContext(encoded)
            }
        } catch {
            dprint("⌚ [Watch] Failed to encode hole filter settings: \(error)")
        }
    }

    // MARK: - Background context updates

    private func mergeIntoApplicationContext(_ newEntries: [String: Any]) {
        var context = WCSession.default.applicationContext
        for (key, value) in newEntries {
            context[key] = value
        }
        do {
            try WCSession.default.updateApplicationContext(context)
        } catch {
            dprint("📱 Failed to update application context: \(error)")
        }
    }

    private func updateHoleDetectionContext(_ data: Data) {
        mergeIntoApplicationContext(["holeDetectionData": data])
    }

    private func updateHoleFilterSettingsContext(_ data: Data) {
        mergeIntoApplicationContext(["holeFilterSettings": data])
    }

    // MARK: - Auth Session (iPhone → Watch)

    /// Mirrors the Supabase auth session to the Watch via application context.
    /// Pass nil to signal sign-out (Watch clears its stored session).
    /// Application context = latest-wins, persistent across the wire.
    func sendAuthSession(_ session: AuthSession?) {
        if let session = session, let data = try? JSONEncoder().encode(session) {
            mergeIntoApplicationContext(["authSession": data])
            // Also sendMessage for live delivery — applicationContext is
            // durable but coalescing-only and may not arrive immediately.
            // The dual path matches the dev-param / debug-logging pattern.
            guard WCSession.default.activationState == .activated,
                  WCSession.default.isReachable else { return }
            WCSession.default.sendMessage(
                ["type": "authSession", "data": data],
                replyHandler: nil,
                errorHandler: nil
            )
        } else {
            mergeIntoApplicationContext(["authSession": Data()])
            guard WCSession.default.activationState == .activated,
                  WCSession.default.isReachable else { return }
            WCSession.default.sendMessage(
                ["type": "authSession", "data": Data()],
                replyHandler: nil,
                errorHandler: nil
            )
        }
    }

    /// Watch → iPhone: ask for the current auth session to be re-sent. Used
    /// by the watch's auto-recovery flow when a Supabase call returns 401
    /// — the watch may have a stale session and the iPhone has a fresh one.
    /// iPhone responds by calling sendAuthSession with whatever it has.
    func requestAuthSessionRefresh() {
        #if os(watchOS)
        guard WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(
            ["type": "requestAuthSession"],
            replyHandler: nil,
            errorHandler: nil
        )
        #endif
    }

    // MARK: - Debug logging toggle (iPhone → Watch)

    /// Mirror the ClientEventLogger on/off toggle to the watch so debug
    /// logging stays in sync across devices when toggled in iPhone Settings.
    func sendDebugLoggingEnabled(_ enabled: Bool) {
        mergeIntoApplicationContext(["clientEventLoggerEnabled": enabled])
        guard WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(
            ["type": "clientEventLoggerEnabled", "value": enabled],
            replyHandler: nil,
            errorHandler: nil
        )
    }

    // MARK: - Dev parameter sync (iPhone → Watch)

    /// Mirror a UserDefaults dev-section parameter to the watch. iPhone is
    /// the authority for these (the slider/stepper lives there); watch
    /// reads from its own UserDefaults so this just keeps the two stores
    /// in sync. Both `Double` and `Int` paths use the same key.
    func sendDevParam(key: String, doubleValue: Double) {
        sendDevParamPayload([key: doubleValue])
    }
    func sendDevParam(key: String, intValue: Int) {
        sendDevParamPayload([key: intValue])
    }
    func sendDevParam(key: String, boolValue: Bool) {
        sendDevParamPayload([key: boolValue])
    }
    func sendDevParam(key: String, stringValue: String) {
        sendDevParamPayload([key: stringValue])
    }
    private func sendDevParamPayload(_ payload: [String: Any]) {
        var contextPayload: [String: Any] = (WCSession.default.applicationContext["devParams"] as? [String: Any]) ?? [:]
        for (k, v) in payload { contextPayload[k] = v }
        mergeIntoApplicationContext(["devParams": contextPayload])
        guard WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return }
        var msg = payload
        msg["type"] = "devParam"
        WCSession.default.sendMessage(msg, replyHandler: nil) { _ in }
    }

    // MARK: - Hole detection request (Watch → iPhone)

    /// Watch asks the iPhone to run blob hole-detection for a course it just
    /// started a round on. iPhone responds asynchronously via the existing
    /// `sendHoleDetectionData` flow once the analyzer finishes (or sends
    /// the cached result immediately if it has one). Used so the watch can
    /// compare blob-detected greens against OSM green polygons even when
    /// the iOS user never explicitly opted into hole detection on iPhone.
    func sendHoleDetectionRequest(courseId: UUID) {
        guard WCSession.default.activationState == .activated else { return }
        let payload: [String: Any] = [
            "type": "holeDetectionRequest",
            "courseId": courseId.uuidString
        ]
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: nil) { _ in }
        } else {
            // applicationContext can deliver to the iPhone when the watch
            // app isn't currently driving WC traffic; iPhone-side handler
            // looks for the same key. Latest-wins is fine; multiple watch
            // restarts just re-request the same course.
            mergeIntoApplicationContext(["holeDetectionRequest": [
                "courseId": courseId.uuidString
            ]])
        }
    }

    // MARK: - Test mode state (iPhone → Watch)

    /// Push the test-mode state to the watch. Used because non-LTE watches
    /// can't open WebSockets (URLSessionWebSocketTask doesn't ride the
    /// phone-tether proxy that ordinary HTTPS uses), so the Realtime
    /// subscribe path on the watch dies immediately. WatchConnectivity is
    /// the right transport: rock-solid over Bluetooth tether, no auth, no
    /// reconnect logic.
    ///
    /// Sends both via `sendMessage` (immediate when watch reachable) AND
    /// updates application context (latest-wins, delivered on next watch
    /// app launch if the message didn't make it). Belt-and-suspenders.
    func sendTestModeState(enabled: Bool, lat: Double?, lon: Double?) {
        var payload: [String: Any] = ["enabled": enabled]
        if let lat = lat { payload["lat"] = lat }
        if let lon = lon { payload["lon"] = lon }
        mergeIntoApplicationContext(["testModeState": payload])
        guard WCSession.default.activationState == .activated else { return }
        if WCSession.default.isReachable {
            var message = payload
            message["type"] = "testModeState"
            WCSession.default.sendMessage(message, replyHandler: nil) { _ in }
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityManager: WCSessionDelegate {

    // MARK: Receiving Messages (Immediate)

    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        // Hole detection data (iPhone → Watch)
        if let type = message["type"] as? String, type == "holeDetectionData",
           let data = message["data"] as? Data,
           let detectionData = try? JSONDecoder().decode(CourseHoleDetectionData.self, from: data) {
            DispatchQueue.main.async {
                self.onReceiveHoleDetectionData?(detectionData)
            }
            return
        }

        // Watch-side diagnostic logs forwarded to phone console
        if let type = message["type"] as? String, type == "watchLog",
           let msg = message["msg"] as? String {
            dprint("⌚→📱 \(msg)")
            return
        }

        // Hole filter settings (Watch → iPhone)
        if let type = message["type"] as? String, type == "holeFilterSettings",
           let data = message["data"] as? Data,
           let settings = try? JSONDecoder().decode(HoleDetectionFilterSettings.self, from: data) {
            DispatchQueue.main.async {
                self.onReceiveHoleFilterSettings?(settings)
            }
            return
        }

        // Test mode state (iPhone → Watch). Uses sendMessage for sub-second
        // delivery while watch is reachable; applicationContext catches the
        // not-reachable / cold-launch case.
        #if os(watchOS)
        if let type = message["type"] as? String, type == "testModeState" {
            applyTestModePayload(message)
            return
        }
        #endif

        // Hole detection request (Watch → iPhone). iPhone runs the
        // analyzer for the named course and ships results back through
        // the existing sendHoleDetectionData flow.
        #if os(iOS)
        if let type = message["type"] as? String, type == "holeDetectionRequest",
           let courseIdString = message["courseId"] as? String,
           let courseId = UUID(uuidString: courseIdString) {
            DispatchQueue.main.async {
                self.onReceiveHoleDetectionRequest?(courseId)
            }
            return
        }
        #endif

        // Debug logging toggle from iPhone — apply to watch's UserDefaults
        // so ClientEventLogger.enabled tracks the iPhone setting.
        #if os(watchOS)
        if let type = message["type"] as? String, type == "clientEventLoggerEnabled",
           let value = message["value"] as? Bool {
            DispatchQueue.main.async {
                ClientEventLogger.setEnabled(value)
            }
            return
        }

        // Dev-section parameter mirror — write to local UserDefaults so the
        // consumer (AutoAdvanceMonitor / SwingDetectionManager / etc.) picks
        // up the new value on its next read. Also poke the SwingDetectionManager
        // @Published vars directly when they're the ones backing the value
        // (otherwise the UserDefaults write wouldn't reach the live object).
        if let type = message["type"] as? String, type == "devParam" {
            DispatchQueue.main.async {
                for (k, v) in message where k != "type" {
                    UserDefaults.standard.set(v, forKey: k)
                    self.applyDevParamToLiveObjects(key: k, value: v)
                }
            }
            return
        }

        // Live-delivery auth session push from iPhone — same payload as the
        // applicationContext path but no coalescing delay. Used by the
        // watch's auto-recovery flow when a Supabase call returned 401.
        if let type = message["type"] as? String, type == "authSession",
           let data = message["data"] as? Data {
            DispatchQueue.main.async {
                if data.isEmpty {
                    WatchAuthSession.shared.apply(nil)
                } else if let session = try? JSONDecoder().decode(AuthSession.self, from: data) {
                    WatchAuthSession.shared.apply(session)
                }
            }
            return
        }
        #endif

        // Watch asks iPhone to re-send current AuthSession. Triggered by
        // the watch's recovery path when its Supabase calls 401. iPhone
        // forwards whatever it has via the existing dual-channel push.
        #if os(iOS)
        if let type = message["type"] as? String, type == "requestAuthSession" {
            DispatchQueue.main.async {
                self.sendAuthSession(AuthManager.shared.session)
            }
            return
        }
        #endif
    }

    // MARK: Receiving Application Context (Background)

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        // Hole detection data
        if let data = applicationContext["holeDetectionData"] as? Data,
           let detectionData = try? JSONDecoder().decode(CourseHoleDetectionData.self, from: data) {
            DispatchQueue.main.async { self.onReceiveHoleDetectionData?(detectionData) }
        }

        // Hole filter settings
        if let data = applicationContext["holeFilterSettings"] as? Data,
           let settings = try? JSONDecoder().decode(HoleDetectionFilterSettings.self, from: data) {
            DispatchQueue.main.async { self.onReceiveHoleFilterSettings?(settings) }
        }

        // Auth session mirrored from iPhone (Watch-only consumer).
        // Empty Data == explicit sign-out sentinel; absent key == no change.
        #if os(watchOS)
        if let data = applicationContext["authSession"] as? Data {
            if data.isEmpty {
                WatchAuthSession.shared.apply(nil)
            } else if let session = try? JSONDecoder().decode(AuthSession.self, from: data) {
                WatchAuthSession.shared.apply(session)
            }
        }

        // Test mode state mirrored from iPhone. Fires on app launch with
        // the latest state since applicationContext is latest-wins persistent.
        if let payload = applicationContext["testModeState"] as? [String: Any] {
            applyTestModePayload(payload)
        }
        #endif

        // Hole detection request from watch via applicationContext —
        // delivered when watch wasn't reachable at the time of the original
        // sendMessage. iPhone-only consumer.
        #if os(iOS)
        if let payload = applicationContext["holeDetectionRequest"] as? [String: Any],
           let courseIdString = payload["courseId"] as? String,
           let courseId = UUID(uuidString: courseIdString) {
            DispatchQueue.main.async {
                self.onReceiveHoleDetectionRequest?(courseId)
            }
        }
        #endif

        // Debug logging toggle mirrored from iPhone via applicationContext
        // (latest-wins, persists across watch app launches).
        #if os(watchOS)
        if let value = applicationContext["clientEventLoggerEnabled"] as? Bool {
            DispatchQueue.main.async {
                ClientEventLogger.setEnabled(value)
            }
        }

        // Dev-section parameters mirrored from iPhone via applicationContext.
        if let params = applicationContext["devParams"] as? [String: Any] {
            DispatchQueue.main.async {
                for (k, v) in params {
                    UserDefaults.standard.set(v, forKey: k)
                    self.applyDevParamToLiveObjects(key: k, value: v)
                }
            }
        }
        #endif
    }

    #if os(watchOS)
    /// Writes-through dev params to the live @Published vars on the
    /// services that hold them. Without this, UserDefaults updates land
    /// but the runtime objects keep stale values until they're rebuilt.
    /// AutoAdvance + step gate read UserDefaults dynamically (no @Published),
    /// so they don't need a poke; ignorePracticeRadius does.
    private func applyDevParamToLiveObjects(key: String, value: Any) {
        let m = SwingDetectionManager.shared
        switch key {
        case "ignorePracticeRadius":         if let d = value as? Double { m.ignorePracticeRadius = d }
        case "autoAdd":                      if let b = value as? Bool   { m.autoAdd = b }
        case "detectionMode":                if let s = value as? String, let mode = DetectionMode(rawValue: s) { m.detectionMode = mode; m.resetToIdle() }
        case "unifPreset":                   if let s = value as? String, let p = UnifDetectPreset(rawValue: s) { m.applyUnifPreset(p) }
        case "unifSetupCeiling":             if let d = value as? Double { m.unifSetupCeiling = d }
        case "unifSetupMinDur":              if let d = value as? Double { m.unifSetupMinDur = d }
        case "unifValleyProm":               if let d = value as? Double { m.unifValleyProm = d }
        case "unifPeakProm":                 if let d = value as? Double { m.unifPeakProm = d }
        case "unifValleyDist":               if let i = value as? Int    { m.unifValleyDist = i }
        case "unifPeakDist":                 if let i = value as? Int    { m.unifPeakDist = i }
        case "unifAreaWindow":               if let d = value as? Double { m.unifAreaWindow = d }
        case "unifBsMaxRotMag":              if let d = value as? Double { m.unifBsMaxRotMag = d }
        case "unifSwingFSAreaThresh":        if let d = value as? Double { m.unifSwingFSAreaThresh = d }
        case "unifContactTVSumMin":          if let d = value as? Double { m.unifContactTVSumMin = d }
        case "unifContactMinExtrema":        if let i = value as? Int    { m.unifContactMinExtrema = i }
        case "unifExtremaSpreadMax":         if let d = value as? Double { m.unifExtremaSpreadMax = d }
        case "unifBaselineTVMax":            if let d = value as? Double { m.unifBaselineTVMax = d }
        case "unifContactProminence":        if let d = value as? Double { m.unifContactProminence = d }
        case "unifContactWindowRight":       if let d = value as? Double { m.unifContactWindowRight = d }
        case "unifMaxReversals":             if let i = value as? Int    { m.unifMaxReversals = i }
        case "unifBsToFsMin":                if let d = value as? Double { m.unifBsToFsMin = d }
        case "unifBsToFsMax":                if let d = value as? Double { m.unifBsToFsMax = d }
        case "unifFSBSRatioMin":             if let d = value as? Double { m.unifFSBSRatioMin = d }
        case "unifPrePeakDtMax":             if let d = value as? Double { m.unifPrePeakDtMax = d }
        default: break
        }
    }
    #endif

    #if os(watchOS)
    /// Decode a test-mode payload (from either applicationContext or
    /// sendMessage) and forward to TestModeService. `enabled` is required;
    /// `lat`/`lon` are optional (when test mode is being disabled they
    /// won't be present).
    private func applyTestModePayload(_ payload: [String: Any]) {
        let enabled = (payload["enabled"] as? Bool) ?? false
        let lat = payload["lat"] as? Double
        let lon = payload["lon"] as? Double
        DispatchQueue.main.async {
            TestModeService.shared.applyFromWatchConnectivity(enabled: enabled, lat: lat, lon: lon)
        }
    }
    #endif

    // MARK: Receiving File Transfers

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        #if os(watchOS)
        if let type = file.metadata?["type"] as? String, type == "holeDetectionData" {
            guard let fileData = try? Data(contentsOf: file.fileURL),
                  let detectionData = try? JSONDecoder().decode(CourseHoleDetectionData.self, from: fileData) else {
                return
            }
            DispatchQueue.main.async {
                self.onReceiveHoleDetectionData?(detectionData)
            }
        }
        // iOS no longer accepts motion file transfers — swing CSVs go
        // directly from watch to Supabase. Any inbound legacy file from
        // an older watch build is silently dropped.
        #endif
    }

    // MARK: Session Management

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
            self.isActivated = (activationState == .activated)
        }
        if let error = error {
            dprint("❌ WCSession activation failed: \(error.localizedDescription)")
        } else {
            DispatchQueue.main.async { self.onSessionActivated?() }
            if let detectionData = self.pendingHoleDetectionData {
                self.actuallySendHoleDetectionData(detectionData)
                self.pendingHoleDetectionData = nil
            }
            if let settings = self.pendingHoleFilterSettings {
                self.actuallySendHoleFilterSettings(settings)
                self.pendingHoleFilterSettings = nil
            }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.isReachable = session.isReachable }
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {
        dprint("WCSession became inactive")
    }

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif
}
