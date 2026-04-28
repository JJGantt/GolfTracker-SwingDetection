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
///   - **Motion data files** (Watch → iPhone): swing CSVs and putt event
///     captures stream as files for analysis on the phone.
class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()

    @Published var isReachable = false
    @Published var isActivated = false

    // Callbacks for received data
    var onReceiveHoleDetectionData: ((CourseHoleDetectionData) -> Void)?
    var onReceiveHoleFilterSettings: ((HoleDetectionFilterSettings) -> Void)?
    var onReceiveMotionData: ((String, Int, Double, Double, String?, Int?) -> Void)?  // CSV, sampleCount, threshold, timeAboveThreshold, rawAccelCsv, rawAccelSampleCount
    var onReceivePuttEventData: ((String, Int, String?, Int?, String) -> Void)?       // csv, sampleCount, rawAccelCsv, rawAccelSampleCount, outcome
    var onReceivePuttDiagnosticLog: ((String, String, String) -> Void)?               // log, outcome, finalState
    var onReceiveMotionFile: ((URL, [String: Any]) -> Void)?                          // tempCopyURL, metadata

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
        } else {
            mergeIntoApplicationContext(["authSession": Data()])
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityManager: WCSessionDelegate {

    // MARK: Receiving Messages (Immediate)

    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        // Motion data (Watch → iPhone)
        if let type = message["type"] as? String, type == "motionData",
           let csv = message["csv"] as? String,
           let sampleCount = message["sampleCount"] as? Int {
            let rawAccelCsv = message["rawAccelCsv"] as? String
            let rawAccelSampleCount = message["rawAccelSampleCount"] as? Int
            DispatchQueue.main.async {
                let accelThreshold = message["accelThreshold"] as? Double ?? message["threshold"] as? Double ?? 2.0
                let accelTimeThreshold = message["accelTimeThreshold"] as? Double ?? message["timeAboveThreshold"] as? Double ?? 0.0
                self.onReceiveMotionData?(csv, sampleCount, accelThreshold, accelTimeThreshold, rawAccelCsv, rawAccelSampleCount)
            }
            return
        }

        // Putt diagnostic log
        if let type = message["type"] as? String, type == "puttDiagnosticLog",
           let log = message["log"] as? String,
           let outcome = message["outcome"] as? String,
           let finalState = message["finalState"] as? String {
            DispatchQueue.main.async {
                self.onReceivePuttDiagnosticLog?(log, outcome, finalState)
            }
            return
        }

        // Putt event data
        if let type = message["type"] as? String, type == "puttEventData",
           let csv = message["csv"] as? String,
           let sampleCount = message["sampleCount"] as? Int {
            let rawAccelCsv = message["rawAccelCsv"] as? String
            let rawAccelSampleCount = message["rawAccelSampleCount"] as? Int
            let diagnosticLog = message["diagnosticLog"] as? String
            let outcome = message["outcome"] as? String ?? "detected"
            let finalState = message["finalState"] as? String ?? ""
            DispatchQueue.main.async {
                self.onReceivePuttEventData?(csv, sampleCount, rawAccelCsv, rawAccelSampleCount, outcome)
                if let log = diagnosticLog, !log.isEmpty {
                    self.onReceivePuttDiagnosticLog?(log, outcome, finalState)
                }
            }
            return
        }

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
        #endif
    }

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
            return
        }
        #else
        let fileName = file.fileURL.lastPathComponent
        let metadata = file.metadata ?? [:]
        let fileType = metadata["type"] as? String ?? ""
        guard fileType == "motionData" || fileType == "puttEventData" || fileType == "continuousLog"
                || fileType == "rollingSnapshot" || fileType == "detectionEventData" || fileType == "undoMotionData"
                || fileType == "falsePositive" || fileType == "swingDataLog" else {
            return
        }
        let tempCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("received_\(fileName)")
        do {
            try? FileManager.default.removeItem(at: tempCopy)
            try FileManager.default.copyItem(at: file.fileURL, to: tempCopy)
            DispatchQueue.main.async {
                self.onReceiveMotionFile?(tempCopy, metadata)
            }
        } catch {
            dprint("📱 [iPhone] Failed to copy received motion file \(fileName): \(error)")
        }
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
