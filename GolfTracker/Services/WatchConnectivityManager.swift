import Foundation
import WatchConnectivity

class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()

    @Published var isReachable = false
    @Published var isActivated = false

    // Callbacks for received data
    var onReceiveRound: ((Round) -> Void)?
    var onReceiveStrokes: (([Stroke]) -> Void)?
    var onReceiveClubs: (([ClubData]) -> Void)?
    var onReceiveClubTypes: (([ClubTypeData]) -> Void)?
    var onReceiveHoleDetectionData: ((CourseHoleDetectionData) -> Void)?
    var onReceiveHoleFilterSettings: ((HoleDetectionFilterSettings) -> Void)?
    var onReceiveMotionData: ((String, Int, Double, Double, String?, Int?) -> Void)? // CSV, sampleCount, threshold, timeAboveThreshold, rawAccelCsv, rawAccelSampleCount
    var onReceivePuttEventData: ((String, Int, String?, Int?, String) -> Void)? // csv, sampleCount, rawAccelCsv, rawAccelSampleCount, outcome
    var onReceivePuttDiagnosticLog: ((String, String, String) -> Void)? // log, outcome, finalState
    var onReceiveMotionFile: ((URL, [String: Any]) -> Void)? // tempCopyURL, metadata

    // Queue for pending sends
    private var pendingRound: Round?
    private var pendingClubs: [ClubData]?
    private var pendingClubTypes: [ClubTypeData]?
    private var pendingHoleDetectionData: CourseHoleDetectionData?
    private var pendingHoleFilterSettings: HoleDetectionFilterSettings?

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    // MARK: - Sending Data

    /// Send current round to Watch (iPhone → Watch)
    func sendRound(_ round: Round) {
        dprint("📱 [iPhone] sendRound called - activation state: \(WCSession.default.activationState.rawValue)")
        dprint("📱 [iPhone] isReachable: \(WCSession.default.isReachable)")

        guard WCSession.default.activationState == .activated else {
            dprint("📱 [iPhone] Session not activated yet, queuing round for later...")
            pendingRound = round
            return
        }

        actuallysSendRound(round)
    }

    private func actuallysSendRound(_ round: Round) {
        do {
            let data = try JSONEncoder().encode(round)
            dprint("📱 [iPhone] Encoded round data: \(data.count) bytes")
            dprint("📱 [iPhone] Round has \(round.holes.count) holes")

            if WCSession.default.isReachable {
                // Send immediately if Watch is reachable
                dprint("📱 [iPhone] Watch is reachable, sending immediately...")
                WCSession.default.sendMessageData(data, replyHandler: nil) { error in
                    dprint("📱 [iPhone] Failed to send round: \(error.localizedDescription)")
                    // Fallback to background sync
                    self.updateRoundContext(data)
                }
            } else {
                // Queue for background delivery
                dprint("📱 [iPhone] Watch not reachable, using background context")
                updateRoundContext(data)
            }
        } catch {
            dprint("📱 [iPhone] Failed to encode round: \(error)")
        }
    }

    /// Send strokes to iPhone (Watch → iPhone)
    func sendStrokes(_ strokes: [Stroke], completion: @escaping (Bool) -> Void) {
        dprint("⌚ [Watch] sendStrokes called with \(strokes.count) strokes")
        dprint("⌚ [Watch] isReachable: \(WCSession.default.isReachable)")

        guard WCSession.default.activationState == .activated else {
            dprint("⌚ [Watch] ERROR: Session not activated")
            completion(false)
            return
        }

        do {
            let data = try JSONEncoder().encode(strokes)
            dprint("⌚ [Watch] Encoded \(data.count) bytes of stroke data")

            if WCSession.default.isReachable {
                // Send immediately
                dprint("⌚ [Watch] iPhone is reachable, sending immediately...")
                WCSession.default.sendMessageData(data) { _ in
                    dprint("⌚ [Watch] Immediate send successful")
                    completion(true)
                } errorHandler: { error in
                    dprint("⌚ [Watch] Immediate send failed: \(error.localizedDescription)")
                    dprint("⌚ [Watch] Falling back to background context")
                    // Fallback to background sync
                    self.updateStrokesContext(data)
                    completion(true)
                }
            } else {
                // Queue for background delivery
                dprint("⌚ [Watch] iPhone not reachable, using background context")
                updateStrokesContext(data)
                completion(true)
            }
        } catch {
            dprint("⌚ [Watch] Failed to encode strokes: \(error)")
            completion(false)
        }
    }

    /// Send clubs to Watch (iPhone → Watch)
    func sendClubs(_ clubs: [ClubData]) {
        dprint("📱 [iPhone] sendClubs called with \(clubs.count) clubs")

        guard WCSession.default.activationState == .activated else {
            dprint("📱 [iPhone] Session not activated yet, queuing clubs for later...")
            pendingClubs = clubs
            return
        }

        actuallySendClubs(clubs)
    }

    private func actuallySendClubs(_ clubs: [ClubData]) {
        do {
            let data = try JSONEncoder().encode(clubs)
            dprint("📱 [iPhone] Encoded clubs data: \(data.count) bytes")

            if WCSession.default.isReachable {
                // Send immediately if Watch is reachable
                dprint("📱 [iPhone] Watch is reachable, sending clubs immediately...")
                let message: [String: Any] = ["type": "clubs", "data": data]
                WCSession.default.sendMessage(message, replyHandler: nil) { error in
                    dprint("📱 [iPhone] Failed to send clubs: \(error.localizedDescription)")
                    // Fallback to background sync
                    self.updateClubsContext(data)
                }
            } else {
                // Queue for background delivery
                dprint("📱 [iPhone] Watch not reachable, using background context for clubs")
                updateClubsContext(data)
            }
        } catch {
            dprint("📱 [iPhone] Failed to encode clubs: \(error)")
        }
    }

    /// Send club types to Watch (iPhone → Watch)
    func sendClubTypes(_ clubTypes: [ClubTypeData]) {
        dprint("📱 [iPhone] sendClubTypes called with \(clubTypes.count) types")

        guard WCSession.default.activationState == .activated else {
            dprint("📱 [iPhone] Session not activated yet, queuing club types for later...")
            pendingClubTypes = clubTypes
            return
        }

        actuallySendClubTypes(clubTypes)
    }

    private func actuallySendClubTypes(_ clubTypes: [ClubTypeData]) {
        do {
            let data = try JSONEncoder().encode(clubTypes)
            dprint("📱 [iPhone] Encoded club types data: \(data.count) bytes")

            if WCSession.default.isReachable {
                // Send immediately if Watch is reachable
                dprint("📱 [iPhone] Watch is reachable, sending club types immediately...")
                let message: [String: Any] = ["type": "clubTypes", "data": data]
                WCSession.default.sendMessage(message, replyHandler: nil) { error in
                    dprint("📱 [iPhone] Failed to send club types: \(error.localizedDescription)")
                    // Fallback to background sync
                    self.updateClubTypesContext(data)
                }
            } else {
                // Queue for background delivery
                dprint("📱 [iPhone] Watch not reachable, using background context for club types")
                updateClubTypesContext(data)
            }
        } catch {
            dprint("📱 [iPhone] Failed to encode club types: \(error)")
        }
    }

    /// Send raw hole-detection blobs for a course (iPhone → Watch)
    func sendHoleDetectionData(_ data: CourseHoleDetectionData) {
        dprint("📱 [iPhone] sendHoleDetectionData called for course \(data.courseId), blobs: \(data.blobs.count)")

        guard WCSession.default.activationState == .activated else {
            dprint("📱 [iPhone] Session not activated yet, queuing hole detection data for later...")
            pendingHoleDetectionData = data
            return
        }

        actuallySendHoleDetectionData(data)
    }

    private func actuallySendHoleDetectionData(_ detectionData: CourseHoleDetectionData) {
        do {
            let encoded = try JSONEncoder().encode(detectionData)
            dprint("📱 [iPhone] Encoded hole detection data: \(encoded.count) bytes")

            let shouldUseFileTransfer: Bool = {
#if targetEnvironment(simulator)
                return false
#else
                return encoded.count > 50_000
#endif
            }()

            // Large payloads are more reliable via file transfer.
            if shouldUseFileTransfer {
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hole_detection_\(detectionData.courseId.uuidString).json")
                try encoded.write(to: tempURL)
                WCSession.default.transferFile(tempURL, metadata: ["type": "holeDetectionData"])
                dprint("📱 [iPhone] Queued hole detection file transfer")
                return
            }

            if WCSession.default.isReachable {
                dprint("📱 [iPhone] Watch is reachable, sending hole detection data immediately...")
                let message: [String: Any] = ["type": "holeDetectionData", "data": encoded]
                WCSession.default.sendMessage(message, replyHandler: nil) { error in
                    dprint("📱 [iPhone] Failed to send hole detection data: \(error.localizedDescription)")
                    self.updateHoleDetectionContext(encoded)
                }
            } else {
                dprint("📱 [iPhone] Watch not reachable, using background context for hole detection data")
                updateHoleDetectionContext(encoded)
            }
        } catch {
            dprint("📱 [iPhone] Failed to encode hole detection data: \(error)")
        }
    }

    /// Send hole filter settings (Watch → iPhone authority remains Watch)
    func sendHoleFilterSettings(_ settings: HoleDetectionFilterSettings) {
        dprint("⌚ [Watch] sendHoleFilterSettings called")

        guard WCSession.default.activationState == .activated else {
            dprint("⌚ [Watch] Session not activated yet, queuing hole filter settings for later...")
            pendingHoleFilterSettings = settings
            return
        }

        actuallySendHoleFilterSettings(settings)
    }

    private func actuallySendHoleFilterSettings(_ settings: HoleDetectionFilterSettings) {
        do {
            let encoded = try JSONEncoder().encode(settings)
            dprint("⌚ [Watch] Encoded hole filter settings: \(encoded.count) bytes")

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

    // MARK: - Background Context Updates

    /// Merges the given key-value pair into the existing application context,
    /// preserving other keys that were previously set.
    private func mergeIntoApplicationContext(_ newEntries: [String: Any]) {
        var context = WCSession.default.applicationContext
        for (key, value) in newEntries {
            context[key] = value
        }
        do {
            try WCSession.default.updateApplicationContext(context)
            dprint("📱 Successfully queued context keys: \(newEntries.keys.joined(separator: ", "))")
        } catch {
            dprint("📱 Failed to update application context: \(error)")
        }
    }

    private func updateRoundContext(_ data: Data) {
        mergeIntoApplicationContext(["round": data])
    }

    private func updateStrokesContext(_ data: Data) {
        mergeIntoApplicationContext(["strokes": data])
    }

    private func updateClubsContext(_ data: Data) {
        mergeIntoApplicationContext(["clubs": data])
    }

    private func updateClubTypesContext(_ data: Data) {
        mergeIntoApplicationContext(["clubTypes": data])
    }

    private func updateHoleDetectionContext(_ data: Data) {
        mergeIntoApplicationContext(["holeDetectionData": data])
    }

    private func updateHoleFilterSettingsContext(_ data: Data) {
        mergeIntoApplicationContext(["holeFilterSettings": data])
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityManager: WCSessionDelegate {

    // MARK: - Receiving Messages (Immediate)

    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        // Handle motion data
        if let type = message["type"] as? String, type == "motionData",
           let csv = message["csv"] as? String,
           let sampleCount = message["sampleCount"] as? Int {
            let rawAccelCsv = message["rawAccelCsv"] as? String
            let rawAccelSampleCount = message["rawAccelSampleCount"] as? Int
            dprint("📱 [iPhone] Received motion data: \(sampleCount) DeviceMotion samples, \(rawAccelSampleCount ?? 0) RawAccel samples")
            DispatchQueue.main.async {
                // Use new parameter names with defaults for backwards compatibility
                let accelThreshold = message["accelThreshold"] as? Double ?? message["threshold"] as? Double ?? 2.0
                let accelTimeThreshold = message["accelTimeThreshold"] as? Double ?? message["timeAboveThreshold"] as? Double ?? 0.0
                self.onReceiveMotionData?(csv, sampleCount, accelThreshold, accelTimeThreshold, rawAccelCsv, rawAccelSampleCount)
            }
            return
        }

        // Handle putt diagnostic log
        if let type = message["type"] as? String, type == "puttDiagnosticLog",
           let log = message["log"] as? String,
           let outcome = message["outcome"] as? String,
           let finalState = message["finalState"] as? String {
            dprint("📱 [iPhone] Received putt diagnostic log: outcome=\(outcome), finalState=\(finalState)")
            DispatchQueue.main.async {
                self.onReceivePuttDiagnosticLog?(log, outcome, finalState)
            }
            return
        }

        // Handle putt event data (auto-captured around putt attempts — both detected and failed)
        if let type = message["type"] as? String, type == "puttEventData",
           let csv = message["csv"] as? String,
           let sampleCount = message["sampleCount"] as? Int {
            let rawAccelCsv = message["rawAccelCsv"] as? String
            let rawAccelSampleCount = message["rawAccelSampleCount"] as? Int
            let diagnosticLog = message["diagnosticLog"] as? String
            let outcome = message["outcome"] as? String ?? "detected"
            let finalState = message["finalState"] as? String ?? ""
            dprint("📱 [iPhone] Received putt attempt data (\(outcome)): \(sampleCount) DeviceMotion, \(rawAccelSampleCount ?? 0) RawAccel samples")
            DispatchQueue.main.async {
                self.onReceivePuttEventData?(csv, sampleCount, rawAccelCsv, rawAccelSampleCount, outcome)
                // Also save bundled diagnostic log if present
                if let log = diagnosticLog, !log.isEmpty {
                    self.onReceivePuttDiagnosticLog?(log, outcome, finalState)
                }
            }
            return
        }

        // Handle hole detection data (iPhone → Watch)
        if let type = message["type"] as? String, type == "holeDetectionData",
           let data = message["data"] as? Data,
           let detectionData = try? JSONDecoder().decode(CourseHoleDetectionData.self, from: data) {
            dprint("⌚ [Watch] Received hole detection data for course \(detectionData.courseId), blobs: \(detectionData.blobs.count)")
            DispatchQueue.main.async {
                self.onReceiveHoleDetectionData?(detectionData)
            }
            return
        }

        // Handle watch-side diagnostic logs forwarded to phone console
        if let type = message["type"] as? String, type == "watchLog",
           let msg = message["msg"] as? String {
            dprint("⌚→📱 \(msg)")
            return
        }

        // Handle hole filter settings (Watch → iPhone)
        if let type = message["type"] as? String, type == "holeFilterSettings",
           let data = message["data"] as? Data,
           let settings = try? JSONDecoder().decode(HoleDetectionFilterSettings.self, from: data) {
            dprint("📱 [iPhone] Received hole filter settings from Watch")
            DispatchQueue.main.async {
                self.onReceiveHoleFilterSettings?(settings)
            }
            return
        }

        // Handle clubs data (iPhone → Watch)
        if let type = message["type"] as? String, type == "clubs",
           let data = message["data"] as? Data,
           let clubs = try? JSONDecoder().decode([ClubData].self, from: data) {
            dprint("⌚ [Watch] Received \(clubs.count) clubs via message")
            DispatchQueue.main.async {
                self.onReceiveClubs?(clubs)
            }
            return
        }

        // Handle club types data (iPhone → Watch)
        if let type = message["type"] as? String, type == "clubTypes",
           let data = message["data"] as? Data,
           let clubTypes = try? JSONDecoder().decode([ClubTypeData].self, from: data) {
            dprint("⌚ [Watch] Received \(clubTypes.count) club types via message")
            DispatchQueue.main.async {
                self.onReceiveClubTypes?(clubTypes)
            }
            return
        }
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        // Try to decode as Round first (iPhone → Watch)
        if let round = try? JSONDecoder().decode(Round.self, from: messageData) {
            DispatchQueue.main.async {
                self.onReceiveRound?(round)
            }
            return
        }

        // Try to decode as Strokes (Watch → iPhone)
        if let strokes = try? JSONDecoder().decode([Stroke].self, from: messageData) {
            DispatchQueue.main.async {
                self.onReceiveStrokes?(strokes)
            }
            return
        }
    }

    // MARK: - Receiving Application Context (Background)

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        dprint("⌚ [Watch] Received application context")

        // Round received
        if let data = applicationContext["round"] as? Data,
           let round = try? JSONDecoder().decode(Round.self, from: data) {
            dprint("⌚ [Watch] Decoded round: \(round.courseName), holes: \(round.holes.count)")
            DispatchQueue.main.async {
                self.onReceiveRound?(round)
            }
        }

        // Strokes received
        if let data = applicationContext["strokes"] as? Data,
           let strokes = try? JSONDecoder().decode([Stroke].self, from: data) {
            dprint("⌚ [Watch] Decoded \(strokes.count) strokes")
            DispatchQueue.main.async {
                self.onReceiveStrokes?(strokes)
            }
        }

        // Clubs received
        if let data = applicationContext["clubs"] as? Data,
           let clubs = try? JSONDecoder().decode([ClubData].self, from: data) {
            dprint("⌚ [Watch] Decoded \(clubs.count) clubs from context")
            DispatchQueue.main.async {
                self.onReceiveClubs?(clubs)
            }
        }

        // Club types received
        if let data = applicationContext["clubTypes"] as? Data,
           let clubTypes = try? JSONDecoder().decode([ClubTypeData].self, from: data) {
            dprint("⌚ [Watch] Decoded \(clubTypes.count) club types from context")
            DispatchQueue.main.async {
                self.onReceiveClubTypes?(clubTypes)
            }
        }

        // Hole detection data received
        if let data = applicationContext["holeDetectionData"] as? Data,
           let detectionData = try? JSONDecoder().decode(CourseHoleDetectionData.self, from: data) {
            dprint("⌚ [Watch] Decoded hole detection data from context, blobs: \(detectionData.blobs.count)")
            DispatchQueue.main.async {
                self.onReceiveHoleDetectionData?(detectionData)
            }
        }

        // Hole filter settings received
        if let data = applicationContext["holeFilterSettings"] as? Data,
           let settings = try? JSONDecoder().decode(HoleDetectionFilterSettings.self, from: data) {
            dprint("📱 [iPhone] Decoded hole filter settings from context")
            DispatchQueue.main.async {
                self.onReceiveHoleFilterSettings?(settings)
            }
        }
    }

    // MARK: - Receiving File Transfers

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        #if os(watchOS)
        dprint("⌚ [Watch] 📥 Received file: \(file.fileURL.lastPathComponent)")
        dprint("⌚ [Watch] File metadata: \(file.metadata ?? [:])")

        if let type = file.metadata?["type"] as? String, type == "holeDetectionData" {
            guard let fileData = try? Data(contentsOf: file.fileURL),
                  let detectionData = try? JSONDecoder().decode(CourseHoleDetectionData.self, from: fileData) else {
                dprint("⌚ [Watch] ❌ ERROR: Failed to decode hole detection file")
                return
            }
            dprint("⌚ [Watch] ✅ Received hole detection file for course \(detectionData.courseId), blobs: \(detectionData.blobs.count)")
            DispatchQueue.main.async {
                self.onReceiveHoleDetectionData?(detectionData)
            }
            return
        }

        dprint("⌚ [Watch] Ignoring unrecognized file: \(file.fileURL.lastPathComponent)")
        #else
        let fileName = file.fileURL.lastPathComponent
        let metadata = file.metadata ?? [:]
        let fileType = metadata["type"] as? String ?? ""

        guard fileType == "motionData" || fileType == "puttEventData" || fileType == "continuousLog"
                || fileType == "rollingSnapshot" || fileType == "detectionEventData" || fileType == "undoMotionData"
                || fileType == "falsePositive" || fileType == "swingDataLog" else {
            dprint("📱 [iPhone] Received unexpected file: \(fileName)")
            return
        }

        // The temp file URL is only valid during this delegate call — copy it immediately.
        let tempCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("received_\(fileName)")
        do {
            try? FileManager.default.removeItem(at: tempCopy)
            try FileManager.default.copyItem(at: file.fileURL, to: tempCopy)
            dprint("📱 [iPhone] Received motion file: \(fileName) (\(fileType))")
            DispatchQueue.main.async {
                self.onReceiveMotionFile?(tempCopy, metadata)
            }
        } catch {
            dprint("📱 [iPhone] Failed to copy received motion file \(fileName): \(error)")
        }
        #endif
    }

    // MARK: - Session Management

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
            self.isActivated = (activationState == .activated)
        }

        if let error = error {
            dprint("❌ WCSession activation failed: \(error.localizedDescription)")
        } else {
            dprint("✅ WCSession activated: state=\(activationState.rawValue), reachable=\(session.isReachable)")

            // Send any pending data now that we're activated
            if let round = self.pendingRound {
                dprint("📱 [iPhone] Session now activated, sending pending round...")
                self.actuallysSendRound(round)
                self.pendingRound = nil
            }
            if let clubs = self.pendingClubs {
                dprint("📱 [iPhone] Session now activated, sending pending clubs...")
                self.actuallySendClubs(clubs)
                self.pendingClubs = nil
            }
            if let clubTypes = self.pendingClubTypes {
                dprint("📱 [iPhone] Session now activated, sending pending club types...")
                self.actuallySendClubTypes(clubTypes)
                self.pendingClubTypes = nil
            }
            if let holeDetectionData = self.pendingHoleDetectionData {
                dprint("📱 [iPhone] Session now activated, sending pending hole detection data...")
                self.actuallySendHoleDetectionData(holeDetectionData)
                self.pendingHoleDetectionData = nil
            }
            if let holeFilterSettings = self.pendingHoleFilterSettings {
                dprint("⌚ [Watch] Session now activated, sending pending hole filter settings...")
                self.actuallySendHoleFilterSettings(holeFilterSettings)
                self.pendingHoleFilterSettings = nil
            }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
        }
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {
        dprint("WCSession became inactive")
    }

    func sessionDidDeactivate(_ session: WCSession) {
        dprint("WCSession deactivated, reactivating...")
        session.activate()
    }
    #endif
}
