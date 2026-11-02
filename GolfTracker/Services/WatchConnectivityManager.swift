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
///
/// Every message and context entry has a typed form in `WatchMessages.swift`;
/// this class only moves them.
///
/// WCSession calls its delegate on a background queue. Each delegate method
/// decodes what it received there and hands the result to main, where the
/// callbacks and published properties live; context writes are serialized by
/// `contextLock`.
final class WatchConnectivityManager: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = WatchConnectivityManager()

    @Published var isReachable = false
    @Published var isActivated = false

    /// Build number of the watch app, as the watch itself reported it.
    ///
    /// The watch app is a separate binary that installs asynchronously after
    /// the phone's copy lands, and it can lag a long way behind — which is
    /// invisible, because neither app displays what it is running. Testing
    /// yesterday's watch code against today's phone code looks exactly like a
    /// bug in today's code. The watch pushes this on every activation;
    /// iPhone-side only, nil until the first context arrives.
    @Published var watchBuild: String?

    /// This target's own build number.
    static var localBuild: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
    }

    // Callbacks for received data
    var onReceiveHoleDetectionData: ((CourseHoleDetectionData) -> Void)?
    var onReceiveHoleFilterSettings: ((HoleDetectionFilterSettings) -> Void)?
    /// Watch asks iPhone to run hole detection for a course id. iPhone-only
    /// callback; consumed by `DataStore` which kicks off `startHoleDetection`.
    var onReceiveHoleDetectionRequest: ((UUID) -> Void)?
    /// iPhone reports progress on a requested analysis. Watch-only consumer.
    var onReceiveHoleDetectionStatus: ((UUID, HoleDetectionPhoneState) -> Void)?
    /// A round row the phone forwarded: (table, kind, JSON record). Watch-only.
    var onReceiveRoundRow: ((String, String, Data) -> Void)?
    /// Fires once activation completes (success path). Currently used by
    /// iOS DataStore to push the authoritative hole-filter settings down
    /// to the watch on each (re)activation.
    var onSessionActivated: (() -> Void)?

    // Pending sends queued until the WC session is activated.
    private var pendingHoleDetectionData: CourseHoleDetectionData?
    private var pendingHoleFilterSettings: HoleDetectionFilterSettings?

    /// Application-context entries not yet written. `updateApplicationContext`
    /// throws until the session is activated, and the phone pushes its login
    /// from `AuthManager.init` — before activation completes — so a write that
    /// is not held here is simply lost and the watch sits at "Sign in on
    /// iPhone" with a signed-in phone. Entries also stay here after a failed
    /// write (watch app not installed yet) and go out with the next one.
    /// Keyed, so it holds at most one value per context key.
    private var pendingContextEntries: [String: Any] = [:]
    /// Serializes context writes: the activation flush runs on the WC delegate
    /// queue, most other writers on main.
    private let contextLock = NSLock()

    #if os(iOS)
    private static let lastHoleDetectionRequestKey = "lastHandledHoleDetectionRequestAt"
    #endif

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
                WCSession.default.sendMessage(WatchMessage.holeDetectionData(encoded).dictionary, replyHandler: nil) { error in
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
                WCSession.default.sendMessage(WatchMessage.holeFilterSettings(encoded).dictionary, replyHandler: nil) { error in
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

    /// Every entry passes through `pendingContextEntries`, so a write before
    /// activation is held rather than dropped, and the first write after it
    /// (the activation flush, or anything later) carries everything held.
    private func mergeIntoApplicationContext(_ key: WatchContextKey, _ value: Any) {
        mergeIntoApplicationContext([key.rawValue: value])
    }

    private func mergeIntoApplicationContext(_ newEntries: [String: Any]) {
        contextLock.lock()
        defer { contextLock.unlock() }
        pendingContextEntries.merge(newEntries) { _, new in new }
        guard WCSession.default.activationState == .activated,
              !pendingContextEntries.isEmpty else { return }
        var context = WCSession.default.applicationContext
        context.merge(pendingContextEntries) { _, new in new }
        do {
            try WCSession.default.updateApplicationContext(context)
            pendingContextEntries = [:]
        } catch {
            dprint("📱 Failed to update application context: \(error)")
        }
    }

    private func updateHoleDetectionContext(_ data: Data) {
        mergeIntoApplicationContext(.holeDetectionData, data)
    }

    private func updateHoleFilterSettingsContext(_ data: Data) {
        mergeIntoApplicationContext(.holeFilterSettings, data)
    }

    // MARK: - Auth Session (iPhone → Watch)

    /// Mirrors the Supabase auth session to the Watch via application context.
    /// Pass nil to signal sign-out (Watch clears its stored session).
    /// Application context = latest-wins, persistent across the wire.
    func sendAuthSession(_ session: AuthSession?) {
        // An empty value is the sign-out sentinel, so a session that fails to
        // encode signs the watch out, as it always has.
        let data = session.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        mergeIntoApplicationContext(.authSession, data)
        // Also sendMessage for live delivery — applicationContext is
        // durable but coalescing-only and may not arrive immediately.
        // The dual path matches the dev-param / debug-logging pattern.
        guard WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(WatchMessage.authSession(data).dictionary, replyHandler: nil, errorHandler: nil)
    }

    /// Watch → iPhone: ask for the current auth session to be re-sent. Used
    /// by the watch's auto-recovery flow when a Supabase call returns 401
    /// — the watch may have a stale session and the iPhone has a fresh one.
    /// iPhone responds by calling sendAuthSession with whatever it has.
    func requestAuthSessionRefresh() {
        #if os(watchOS)
        guard WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(WatchMessage.requestAuthSession.dictionary, replyHandler: nil, errorHandler: nil)
        #endif
    }

    // MARK: - Debug logging toggle (iPhone → Watch)

    /// Mirror the ClientEventLogger on/off toggle to the watch so debug
    /// logging stays in sync across devices when toggled in iPhone Settings.
    func sendDebugLoggingEnabled(_ enabled: Bool) {
        mergeIntoApplicationContext(.clientEventLoggerEnabled, enabled)
        guard WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(WatchMessage.clientEventLoggerEnabled(enabled).dictionary, replyHandler: nil, errorHandler: nil)
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
        var contextPayload: [String: Any] = (WCSession.default.applicationContext[WatchContextKey.devParams.rawValue] as? [String: Any]) ?? [:]
        for (k, v) in payload { contextPayload[k] = v }
        mergeIntoApplicationContext(.devParams, contextPayload)
        guard WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(WatchMessage.devParam(payload).dictionary, replyHandler: nil) { _ in }
    }

    // MARK: - Hole detection request (Watch → iPhone)

    /// Watch asks the iPhone to run blob hole-detection for a course it just
    /// started a round on. The iPhone answers with `sendHoleDetectionStatus`
    /// as it goes (queued / running / done / failed) and ships the blobs
    /// through `sendHoleDetectionData` and the server cache.
    ///
    /// `onUndeliverable` fires when the live message could not reach the
    /// phone — not reachable, or the send errored. The request is still left
    /// in the application context so the phone picks it up on its next launch,
    /// but nothing will happen until then, and the watch has to be able to say
    /// so rather than wait on an answer that is not coming.
    /// `onUndeliverable` may run on WatchConnectivity's queue.
    func sendHoleDetectionRequest(courseId: UUID, onUndeliverable: @escaping @Sendable () -> Void) {
        guard WCSession.default.activationState == .activated else {
            onUndeliverable()
            return
        }
        // `at` identifies the request. It makes each one a distinct context (an
        // identical dictionary is not redelivered, so a re-request for the same
        // course would otherwise never arrive), and it is how the phone tells
        // a new request from this one arriving again: the live message and the
        // context both deliver it, and the context is re-read at every launch.
        let request = HoleDetectionRequest(courseId: courseId, at: Date().timeIntervalSince1970)
        mergeIntoApplicationContext(.holeDetectionRequest, request.dictionary)
        guard WCSession.default.isReachable else {
            onUndeliverable()
            return
        }
        WCSession.default.sendMessage(WatchMessage.holeDetectionRequest(request).dictionary, replyHandler: nil) { _ in onUndeliverable() }
    }

    /// iPhone → Watch progress on a watch-requested blob analysis. Sent both
    /// live and through the application context (latest-wins), so a watch that
    /// was not reachable at the moment still converges on the current state.
    func sendHoleDetectionStatus(courseId: UUID, state: HoleDetectionPhoneState) {
        guard WCSession.default.activationState == .activated else { return }
        let update = HoleDetectionStatusUpdate(courseId: courseId, state: state, at: Date().timeIntervalSince1970)
        mergeIntoApplicationContext(.holeDetectionStatus, update.dictionary)
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(WatchMessage.holeDetectionStatus(update).dictionary, replyHandler: nil) { _ in }
        }
    }

    #if os(iOS)
    /// Runs a watch request once. Without the `at` check the phone re-ran the
    /// last requested course's analysis every time the watch's context was
    /// re-delivered, which happens on every watch launch.
    private func handleHoleDetectionRequest(_ request: HoleDetectionRequest) {
        DispatchQueue.main.async {
            if let at = request.at {
                guard at != UserDefaults.standard.double(forKey: Self.lastHoleDetectionRequestKey) else { return }
                UserDefaults.standard.set(at, forKey: Self.lastHoleDetectionRequestKey)
            }
            self.onReceiveHoleDetectionRequest?(request.courseId)
        }
    }
    #endif

    private func handleHoleDetectionStatus(_ update: HoleDetectionStatusUpdate) {
        DispatchQueue.main.async {
            self.onReceiveHoleDetectionStatus?(update.courseId, update.state)
        }
    }

    // MARK: - Round rows (iPhone → Watch)

    /// Forwards a round row the phone just received from the server (see
    /// `RealtimeSync.relayedTables`). Live when the watch app is reachable,
    /// otherwise `transferUserInfo`, which queues and delivers in order when
    /// the watch app next runs. Applying is idempotent, so a row that goes
    /// both ways after a failed live send is harmless.
    func relayRow(table: String, kind: String, recordJSON: Data) {
        #if os(iOS)
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let payload = WatchMessage.roundRow(RoundRowRelay(table: table, kind: kind, record: recordJSON)).dictionary
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { _ in session.transferUserInfo(payload) }
        } else {
            session.transferUserInfo(payload)
        }
        #endif
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
        let state = TestModeState(enabled: enabled, lat: lat, lon: lon)
        mergeIntoApplicationContext(.testModeState, state.dictionary)
        guard WCSession.default.activationState == .activated else { return }
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(WatchMessage.testModeState(state).dictionary, replyHandler: nil) { _ in }
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityManager: WCSessionDelegate {

    // MARK: Receiving Messages (Immediate)

    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        guard let received = WatchMessage(message) else { return }
        switch received {
        case .holeDetectionData(let data):
            // Hole detection data (iPhone → Watch)
            guard let detectionData = try? JSONDecoder().decode(CourseHoleDetectionData.self, from: data) else { return }
            DispatchQueue.main.async {
                self.onReceiveHoleDetectionData?(detectionData)
            }

        case .watchLog(let msg):
            // Watch-side diagnostic logs forwarded to phone console
            dprint("⌚→📱 \(msg)")

        case .holeFilterSettings(let data):
            // Hole filter settings (Watch → iPhone)
            guard let settings = try? JSONDecoder().decode(HoleDetectionFilterSettings.self, from: data) else { return }
            DispatchQueue.main.async {
                self.onReceiveHoleFilterSettings?(settings)
            }

        #if os(watchOS)
        case .testModeState(let state):
            // Test mode state (iPhone → Watch). Uses sendMessage for sub-second
            // delivery while watch is reachable; applicationContext catches the
            // not-reachable / cold-launch case.
            applyTestModeState(state)

        case .holeDetectionStatus(let update):
            handleHoleDetectionStatus(update)

        case .roundRow(let row):
            receiveRoundRow(row)

        case .clientEventLoggerEnabled(let value):
            // Debug logging toggle from iPhone — apply to watch's UserDefaults
            // so ClientEventLogger.enabled tracks the iPhone setting.
            DispatchQueue.main.async {
                ClientEventLogger.setEnabled(value)
            }

        case .devParam(let params):
            // Dev-section parameter mirror — write to local UserDefaults so the
            // consumer (AutoAdvanceMonitor / SwingDetectionManager / etc.) picks
            // up the new value on its next read. Also poke the SwingDetectionManager
            // @Published vars directly when they're the ones backing the value
            // (otherwise the UserDefaults write wouldn't reach the live object).
            // A received plist dictionary: immutable from here on, so handing
            // it to main is safe although `Any` cannot say so.
            nonisolated(unsafe) let params = params
            DispatchQueue.main.async {
                for (k, v) in params {
                    UserDefaults.standard.set(v, forKey: k)
                    self.applyDevParamToLiveObjects(key: k, value: v)
                }
            }

        case .authSession(let data):
            // Live-delivery auth session push from iPhone — same payload as the
            // applicationContext path but no coalescing delay. Used by the
            // watch's auto-recovery flow when a Supabase call returned 401.
            receiveAuthSessionData(data)
        #endif

        #if os(iOS)
        case .holeDetectionRequest(let request):
            // Hole detection request (Watch → iPhone). iPhone runs the
            // analyzer for the named course and ships results back through
            // the existing sendHoleDetectionData flow.
            handleHoleDetectionRequest(request)

        case .requestAuthSession:
            // Watch asks iPhone to re-send current AuthSession. Triggered by
            // the watch's recovery path when its Supabase calls 401. iPhone
            // forwards whatever it has via the existing dual-channel push.
            DispatchQueue.main.async {
                self.sendAuthSession(AuthManager.shared.currentSession)
            }
        #endif

        default:
            // A message meant for the other device.
            break
        }
    }

    // MARK: Receiving Application Context (Background)

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        handleApplicationContext(applicationContext)
    }

    /// Applies a context from the other device. Runs for every delivered
    /// context and once more at activation on `receivedApplicationContext`,
    /// since a context that arrived while this app was closed does not
    /// reliably fire the delegate. A context always holds EVERY key the sender
    /// has ever set, so each one arrives many times: every key's handler must
    /// be safe to repeat, and the three that are not (the watch's auth
    /// session, the phone's blob request, the watch's dev params) check
    /// whether their value is new.
    private func handleApplicationContext(_ applicationContext: [String: Any]) {
        guard !applicationContext.isEmpty else { return }

        func value(_ key: WatchContextKey) -> Any? { applicationContext[key.rawValue] }

        // Hole detection data
        if let data = value(.holeDetectionData) as? Data,
           let detectionData = try? JSONDecoder().decode(CourseHoleDetectionData.self, from: data) {
            DispatchQueue.main.async { self.onReceiveHoleDetectionData?(detectionData) }
        }

        // Hole filter settings
        if let data = value(.holeFilterSettings) as? Data,
           let settings = try? JSONDecoder().decode(HoleDetectionFilterSettings.self, from: data) {
            DispatchQueue.main.async { self.onReceiveHoleFilterSettings?(settings) }
        }

        // Auth session mirrored from iPhone (Watch-only consumer).
        // Empty Data == explicit sign-out sentinel; absent key == no change.
        #if os(watchOS)
        if let data = value(.authSession) as? Data {
            receiveAuthSessionData(data)
        }

        // Test mode state mirrored from iPhone. Fires on app launch with
        // the latest state since applicationContext is latest-wins persistent.
        if let payload = value(.testModeState) as? [String: Any],
           let state = TestModeState(dictionary: payload) {
            applyTestModeState(state)
        }

        // Latest phone-side state of a requested blob analysis, for a watch
        // that was not reachable when the live message went out.
        if let payload = value(.holeDetectionStatus) as? [String: Any],
           let update = HoleDetectionStatusUpdate(dictionary: payload) {
            handleHoleDetectionStatus(update)
        }
        #endif

        // Watch build number, pushed by the watch on activation.
        #if os(iOS)
        if let build = value(.watchBuild) as? String {
            DispatchQueue.main.async { self.watchBuild = build }
        }
        #endif

        // Hole detection request from watch via applicationContext —
        // delivered when watch wasn't reachable at the time of the original
        // sendMessage. iPhone-only consumer.
        #if os(iOS)
        if let payload = value(.holeDetectionRequest) as? [String: Any],
           let request = HoleDetectionRequest(dictionary: payload) {
            handleHoleDetectionRequest(request)
        }
        #endif

        // Debug logging toggle mirrored from iPhone via applicationContext
        // (latest-wins, persists across watch app launches).
        #if os(watchOS)
        if let enabled = value(.clientEventLoggerEnabled) as? Bool {
            DispatchQueue.main.async {
                ClientEventLogger.setEnabled(enabled)
            }
        }

        // Dev-section parameters mirrored from iPhone via applicationContext.
        // Only changed ones: this dictionary rides along with every context
        // the phone sends (an hourly token refresh included), and applying
        // `detectionMode` resets the swing detector to idle.
        if let received = value(.devParams) as? [String: Any] {
            // Immutable plist values; see the devParam message above.
            nonisolated(unsafe) let params = received
            DispatchQueue.main.async {
                for (k, v) in params {
                    if let current = UserDefaults.standard.object(forKey: k) as? NSObject,
                       current.isEqual(v) { continue }
                    UserDefaults.standard.set(v, forKey: k)
                    self.applyDevParamToLiveObjects(key: k, value: v)
                }
            }
        }
        #endif
    }

    #if os(watchOS)
    /// Empty data is the phone's sign-out sentinel.
    private func receiveAuthSessionData(_ data: Data) {
        let session = data.isEmpty ? nil : try? JSONDecoder().decode(AuthSession.self, from: data)
        if !data.isEmpty && session == nil { return }
        DispatchQueue.main.async {
            WatchAuthSession.shared.receiveFromPhone(session)
        }
    }
    #endif

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
        // Detector thresholds are NOT settable from here any more — they live
        // in `detector_config` and are read at the point of use. A case here
        // would be a second writer racing the table.
        case "detectionMode":                if let s = value as? String, let mode = DetectionMode(rawValue: s) { m.detectionMode = mode; m.resetToIdle() }
        default: break
        }
    }
    #endif

    #if os(watchOS)
    /// Forward a test-mode state (from either applicationContext or
    /// sendMessage) to TestModeService. `lat`/`lon` are absent when test mode
    /// is being disabled.
    private func applyTestModeState(_ state: TestModeState) {
        DispatchQueue.main.async {
            TestModeService.shared.applyFromWatchConnectivity(enabled: state.enabled, lat: state.lat, lon: state.lon)
        }
    }
    #endif

    // MARK: Receiving Queued User Info

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        #if os(watchOS)
        if case .roundRow(let row) = WatchMessage(userInfo) {
            receiveRoundRow(row)
        }
        #endif
    }

    #if os(watchOS)
    private func receiveRoundRow(_ row: RoundRowRelay) {
        DispatchQueue.main.async { self.onReceiveRoundRow?(row.table, row.kind, row.record) }
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
        let reachable = session.isReachable
        DispatchQueue.main.async {
            self.isReachable = reachable
            self.isActivated = (activationState == .activated)
        }
        if let error = error {
            dprint("❌ WCSession activation failed: \(error.localizedDescription)")
        } else {
            DispatchQueue.main.async { self.onSessionActivated?() }
            #if os(watchOS)
            // Report which build the watch is actually running, so the phone's
            // dev menu can show the skew. This write also flushes anything
            // merged before activation.
            self.mergeIntoApplicationContext(.watchBuild, Self.localBuild)
            #else
            self.mergeIntoApplicationContext([:])
            #endif
            self.handleApplicationContext(session.receivedApplicationContext)
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
        let reachable = session.isReachable
        DispatchQueue.main.async { self.isReachable = reachable }
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
