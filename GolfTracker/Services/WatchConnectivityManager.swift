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
    var onReceiveMotionData: ((String, Int, Double, Double, String?, Int?) -> Void)? // CSV, sampleCount, threshold, timeAboveThreshold, rawAccelCsv, rawAccelSampleCount

    // Queue for pending sends
    private var pendingRound: Round?
    private var pendingClubs: [ClubData]?
    private var pendingClubTypes: [ClubTypeData]?

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
        print("📱 [iPhone] sendRound called - activation state: \(WCSession.default.activationState.rawValue)")
        print("📱 [iPhone] isReachable: \(WCSession.default.isReachable)")

        guard WCSession.default.activationState == .activated else {
            print("📱 [iPhone] Session not activated yet, queuing round for later...")
            pendingRound = round
            return
        }

        actuallysSendRound(round)
    }

    private func actuallysSendRound(_ round: Round) {
        do {
            let data = try JSONEncoder().encode(round)
            print("📱 [iPhone] Encoded round data: \(data.count) bytes")
            print("📱 [iPhone] Round has \(round.holes.count) holes")

            if WCSession.default.isReachable {
                // Send immediately if Watch is reachable
                print("📱 [iPhone] Watch is reachable, sending immediately...")
                WCSession.default.sendMessageData(data, replyHandler: nil) { error in
                    print("📱 [iPhone] Failed to send round: \(error.localizedDescription)")
                    // Fallback to background sync
                    self.updateRoundContext(data)
                }
            } else {
                // Queue for background delivery
                print("📱 [iPhone] Watch not reachable, using background context")
                updateRoundContext(data)
            }
        } catch {
            print("📱 [iPhone] Failed to encode round: \(error)")
        }
    }

    /// Send strokes to iPhone (Watch → iPhone)
    func sendStrokes(_ strokes: [Stroke], completion: @escaping (Bool) -> Void) {
        print("⌚ [Watch] sendStrokes called with \(strokes.count) strokes")
        print("⌚ [Watch] isReachable: \(WCSession.default.isReachable)")

        guard WCSession.default.activationState == .activated else {
            print("⌚ [Watch] ERROR: Session not activated")
            completion(false)
            return
        }

        do {
            let data = try JSONEncoder().encode(strokes)
            print("⌚ [Watch] Encoded \(data.count) bytes of stroke data")

            if WCSession.default.isReachable {
                // Send immediately
                print("⌚ [Watch] iPhone is reachable, sending immediately...")
                WCSession.default.sendMessageData(data) { _ in
                    print("⌚ [Watch] Immediate send successful")
                    completion(true)
                } errorHandler: { error in
                    print("⌚ [Watch] Immediate send failed: \(error.localizedDescription)")
                    print("⌚ [Watch] Falling back to background context")
                    // Fallback to background sync
                    self.updateStrokesContext(data)
                    completion(true)
                }
            } else {
                // Queue for background delivery
                print("⌚ [Watch] iPhone not reachable, using background context")
                updateStrokesContext(data)
                completion(true)
            }
        } catch {
            print("⌚ [Watch] Failed to encode strokes: \(error)")
            completion(false)
        }
    }

    /// Send clubs to Watch (iPhone → Watch)
    func sendClubs(_ clubs: [ClubData]) {
        print("📱 [iPhone] sendClubs called with \(clubs.count) clubs")

        guard WCSession.default.activationState == .activated else {
            print("📱 [iPhone] Session not activated yet, queuing clubs for later...")
            pendingClubs = clubs
            return
        }

        actuallySendClubs(clubs)
    }

    private func actuallySendClubs(_ clubs: [ClubData]) {
        do {
            let data = try JSONEncoder().encode(clubs)
            print("📱 [iPhone] Encoded clubs data: \(data.count) bytes")

            if WCSession.default.isReachable {
                // Send immediately if Watch is reachable
                print("📱 [iPhone] Watch is reachable, sending clubs immediately...")
                let message: [String: Any] = ["type": "clubs", "data": data]
                WCSession.default.sendMessage(message, replyHandler: nil) { error in
                    print("📱 [iPhone] Failed to send clubs: \(error.localizedDescription)")
                    // Fallback to background sync
                    self.updateClubsContext(data)
                }
            } else {
                // Queue for background delivery
                print("📱 [iPhone] Watch not reachable, using background context for clubs")
                updateClubsContext(data)
            }
        } catch {
            print("📱 [iPhone] Failed to encode clubs: \(error)")
        }
    }

    /// Send club types to Watch (iPhone → Watch)
    func sendClubTypes(_ clubTypes: [ClubTypeData]) {
        print("📱 [iPhone] sendClubTypes called with \(clubTypes.count) types")

        guard WCSession.default.activationState == .activated else {
            print("📱 [iPhone] Session not activated yet, queuing club types for later...")
            pendingClubTypes = clubTypes
            return
        }

        actuallySendClubTypes(clubTypes)
    }

    private func actuallySendClubTypes(_ clubTypes: [ClubTypeData]) {
        do {
            let data = try JSONEncoder().encode(clubTypes)
            print("📱 [iPhone] Encoded club types data: \(data.count) bytes")

            if WCSession.default.isReachable {
                // Send immediately if Watch is reachable
                print("📱 [iPhone] Watch is reachable, sending club types immediately...")
                let message: [String: Any] = ["type": "clubTypes", "data": data]
                WCSession.default.sendMessage(message, replyHandler: nil) { error in
                    print("📱 [iPhone] Failed to send club types: \(error.localizedDescription)")
                    // Fallback to background sync
                    self.updateClubTypesContext(data)
                }
            } else {
                // Queue for background delivery
                print("📱 [iPhone] Watch not reachable, using background context for club types")
                updateClubTypesContext(data)
            }
        } catch {
            print("📱 [iPhone] Failed to encode club types: \(error)")
        }
    }

    // MARK: - Background Context Updates

    private func updateRoundContext(_ data: Data) {
        do {
            try WCSession.default.updateApplicationContext(["round": data])
            print("📱 [iPhone] Successfully queued round in application context")
        } catch {
            print("📱 [iPhone] Failed to update round context: \(error)")
        }
    }

    private func updateStrokesContext(_ data: Data) {
        do {
            try WCSession.default.updateApplicationContext(["strokes": data])
            print("⌚ [Watch] Successfully queued strokes in application context")
        } catch {
            print("⌚ [Watch] Failed to update strokes context: \(error)")
        }
    }

    private func updateClubsContext(_ data: Data) {
        do {
            try WCSession.default.updateApplicationContext(["clubs": data])
            print("📱 [iPhone] Successfully queued clubs in application context")
        } catch {
            print("📱 [iPhone] Failed to update clubs context: \(error)")
        }
    }

    private func updateClubTypesContext(_ data: Data) {
        do {
            try WCSession.default.updateApplicationContext(["clubTypes": data])
            print("📱 [iPhone] Successfully queued club types in application context")
        } catch {
            print("📱 [iPhone] Failed to update club types context: \(error)")
        }
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
            print("📱 [iPhone] Received motion data: \(sampleCount) DeviceMotion samples, \(rawAccelSampleCount ?? 0) RawAccel samples")
            DispatchQueue.main.async {
                // Use new parameter names with defaults for backwards compatibility
                let accelThreshold = message["accelThreshold"] as? Double ?? message["threshold"] as? Double ?? 2.0
                let accelTimeThreshold = message["accelTimeThreshold"] as? Double ?? message["timeAboveThreshold"] as? Double ?? 0.0
                self.onReceiveMotionData?(csv, sampleCount, accelThreshold, accelTimeThreshold, rawAccelCsv, rawAccelSampleCount)
            }
            return
        }

        // Handle clubs data (iPhone → Watch)
        if let type = message["type"] as? String, type == "clubs",
           let data = message["data"] as? Data,
           let clubs = try? JSONDecoder().decode([ClubData].self, from: data) {
            print("⌚ [Watch] Received \(clubs.count) clubs via message")
            DispatchQueue.main.async {
                self.onReceiveClubs?(clubs)
            }
            return
        }

        // Handle club types data (iPhone → Watch)
        if let type = message["type"] as? String, type == "clubTypes",
           let data = message["data"] as? Data,
           let clubTypes = try? JSONDecoder().decode([ClubTypeData].self, from: data) {
            print("⌚ [Watch] Received \(clubTypes.count) club types via message")
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
        print("⌚ [Watch] Received application context")

        // Round received
        if let data = applicationContext["round"] as? Data,
           let round = try? JSONDecoder().decode(Round.self, from: data) {
            print("⌚ [Watch] Decoded round: \(round.courseName), holes: \(round.holes.count)")
            DispatchQueue.main.async {
                self.onReceiveRound?(round)
            }
        }

        // Strokes received
        if let data = applicationContext["strokes"] as? Data,
           let strokes = try? JSONDecoder().decode([Stroke].self, from: data) {
            print("⌚ [Watch] Decoded \(strokes.count) strokes")
            DispatchQueue.main.async {
                self.onReceiveStrokes?(strokes)
            }
        }

        // Clubs received
        if let data = applicationContext["clubs"] as? Data,
           let clubs = try? JSONDecoder().decode([ClubData].self, from: data) {
            print("⌚ [Watch] Decoded \(clubs.count) clubs from context")
            DispatchQueue.main.async {
                self.onReceiveClubs?(clubs)
            }
        }

        // Club types received
        if let data = applicationContext["clubTypes"] as? Data,
           let clubTypes = try? JSONDecoder().decode([ClubTypeData].self, from: data) {
            print("⌚ [Watch] Decoded \(clubTypes.count) club types from context")
            DispatchQueue.main.async {
                self.onReceiveClubTypes?(clubTypes)
            }
        }
    }

    // MARK: - Receiving File Transfers

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        #if os(watchOS)
        print("⌚ [Watch] 📥 Received file: \(file.fileURL.lastPathComponent)")
        print("⌚ [Watch] File metadata: \(file.metadata ?? [:])")

        // Decode metadata
        guard let metadataJSON = file.metadata?["metadata"] as? Data,
              let metadata = try? JSONDecoder().decode(SatelliteImageMetadata.self, from: metadataJSON) else {
            print("⌚ [Watch] ❌ ERROR: Failed to decode satellite metadata")
            print("⌚ [Watch] Raw metadata: \(file.metadata ?? [:])")
            return
        }

        print("⌚ [Watch] 📋 Decoded metadata for hole \(metadata.holeNumber), courseId: \(metadata.courseId)")

        // Read image data from transferred file
        guard let imageData = try? Data(contentsOf: file.fileURL) else {
            print("⌚ [Watch] ❌ ERROR: Failed to read image data from \(file.fileURL.lastPathComponent)")
            return
        }

        print("⌚ [Watch] ✅ Successfully read \(imageData.count / 1024)KB for hole \(metadata.holeNumber)")

        // Save to Watch cache
        print("⌚ [Watch] 💾 Calling saveImage...")
        WatchSatelliteCacheManager.shared.saveImage(metadata: metadata, imageData: imageData)
        print("⌚ [Watch] ✅✅ COMPLETED satellite image save for hole \(metadata.holeNumber)")
        #else
        print("📱 [iPhone] Received file (unexpected on iPhone): \(file.fileURL.lastPathComponent)")
        #endif
    }

    // MARK: - Session Management

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
            self.isActivated = (activationState == .activated)
        }

        if let error = error {
            print("❌ WCSession activation failed: \(error.localizedDescription)")
        } else {
            print("✅ WCSession activated: state=\(activationState.rawValue), reachable=\(session.isReachable)")

            // Send any pending data now that we're activated
            if let round = self.pendingRound {
                print("📱 [iPhone] Session now activated, sending pending round...")
                self.actuallysSendRound(round)
                self.pendingRound = nil
            }
            if let clubs = self.pendingClubs {
                print("📱 [iPhone] Session now activated, sending pending clubs...")
                self.actuallySendClubs(clubs)
                self.pendingClubs = nil
            }
            if let clubTypes = self.pendingClubTypes {
                print("📱 [iPhone] Session now activated, sending pending club types...")
                self.actuallySendClubTypes(clubTypes)
                self.pendingClubTypes = nil
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
        print("WCSession became inactive")
    }

    func sessionDidDeactivate(_ session: WCSession) {
        print("WCSession deactivated, reactivating...")
        session.activate()
    }
    #endif
}
