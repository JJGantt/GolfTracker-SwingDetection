import Foundation
import WatchConnectivity

class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()

    @Published var isReachable = false
    @Published var isActivated = false

    // Callbacks for received data
    var onReceiveRound: ((Round) -> Void)?
    var onReceiveStrokes: (([Stroke]) -> Void)?
    var onReceiveMotionData: ((String, Int, Double, Double) -> Void)? // CSV, sampleCount, threshold, timeAboveThreshold

    // Queue for pending sends
    private var pendingRound: Round?

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
}

// MARK: - WCSessionDelegate

extension WatchConnectivityManager: WCSessionDelegate {

    // MARK: - Receiving Messages (Immediate)

    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        // Handle motion data
        if let type = message["type"] as? String, type == "motionData",
           let csv = message["csv"] as? String,
           let sampleCount = message["sampleCount"] as? Int,
           let threshold = message["threshold"] as? Double,
           let timeAboveThreshold = message["timeAboveThreshold"] as? Double {
            print("📱 [iPhone] Received motion data: \(sampleCount) samples")
            DispatchQueue.main.async {
                self.onReceiveMotionData?(csv, sampleCount, threshold, timeAboveThreshold)
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

            // Send any pending round now that we're activated
            if let round = self.pendingRound {
                print("📱 [iPhone] Session now activated, sending pending round...")
                self.actuallysSendRound(round)
                self.pendingRound = nil
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
