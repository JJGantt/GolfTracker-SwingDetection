import Foundation
import Combine
import WatchKit

/// Swing Test Mode — detector tuning without a round.
///
/// Runs the detector exactly as round play does (same gates, same thresholds,
/// same haptics, same uploads) but starts no round: no course, no holes, no
/// strokes, no GPS requirement. Its whole purpose is to make the three
/// outcomes we tune against cheap to produce and unambiguous to label:
///
///   * **true positive** — it fired and it was a swing. No button. The counter
///     increments and the wrist buzzes, exactly as in a round.
///   * **false positive** — it fired and it wasn't. One button, flipping the
///     event to false_positive/high.
///   * **false negative** — you swung and nothing happened. One button,
///     uploading the raw motion window (see `captureLookback`).
///
/// The counters exist because the whole exercise depends on knowing whether a
/// swing registered at all, and on a watch the only other signal is a haptic
/// you might have missed.
@MainActor
final class SwingTestSession: ObservableObject {
    static let shared = SwingTestSession()

    @Published private(set) var isRunning = false
    /// Every detection the detector fired, good or bad. Not what the HIT
    /// counter shows — see `truePositiveCount`.
    @Published private(set) var detectedCount = 0
    @Published private(set) var falsePositiveCount = 0
    @Published private(set) var lookbackCount = 0

    /// Detections the user did not flag — what HIT displays.
    ///
    /// HIT used to show `detectedCount`, so a misfire incremented the green
    /// counter AND the red one, and the number the eye lands on first was
    /// really "times the detector fired" rather than "times it was right".
    /// Marking a false positive now takes it back out, so HIT + FP is the
    /// total and HIT alone answers the question the mode exists to ask.
    var truePositiveCount: Int { max(0, detectedCount - falsePositiveCount) }
    /// How many detections are still unmarked and therefore still markable.
    /// Surfaced so the count of remaining presses is visible rather than
    /// guessed — see `unmarkedEventIds`.
    @Published private(set) var markableCount = 0
    /// Brief post-press acknowledgement. Not a gate: with a stack behind it the
    /// button stays live as long as anything is left to mark.
    @Published private(set) var justMarked = false
    @Published private(set) var lastEventAt: Date?

    private var sessionId: UUID?

    /// Detections not yet marked a false positive, oldest first.
    ///
    /// This was a single `lastEventId` slot, which quietly lost data whenever
    /// two detections landed before the user could react: the second overwrote
    /// the first, and the first stayed `positive/low` forever — filed in the
    /// training set as a correct detection. Bursts are exactly when that
    /// happens (fidgeting, setting the club down, walking), so the failure
    /// case was the common one, and it was invisible: the counter showed five
    /// detections, three got marked, and two misfires were recorded as right.
    ///
    /// A stack instead, matching the round's undo button walking back through
    /// `autoAddStack`. Each press pops the most recent, so consecutive false
    /// positives can be cleared after the fact rather than only between them.
    private var unmarkedEventIds: [UUID] = []
    private var cancellables = Set<AnyCancellable>()

    /// Optional club for the session. Written to `club_type` on every row the
    /// session produces; null when unselected. Also applied to the detector so
    /// the putter-specific paths behave as they would in a round.
    @Published var clubTypeName: String? = nil {
        didSet { if isRunning { detector.selectedClubTypeName = clubTypeName } }
    }

    /// Optional note. Session-scoped and persistent: once set, every event
    /// saved while it is active — detection, false-positive mark, miss — is
    /// linked to it. Changing the text starts a new note; clearing it stops
    /// linking. Lives in its own table so round swings never carry one.
    @Published private(set) var noteText: String = ""
    private var activeNoteId: UUID?

    /// Detector settings this mode overrides, restored on stop so a test
    /// session can never leave the app configured differently for a round.
    private var savedAutoAdd: Bool?
    private var savedClubTypeName: String??

    private let detector = SwingDetectionManager.shared

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        let id = UUID()
        sessionId = id
        detectedCount = 0
        falsePositiveCount = 0
        lookbackCount = 0
        unmarkedEventIds.removeAll()
        markableCount = 0
        justMarked = false
        lastEventAt = nil

        // Auto-add is what makes the uploader publish an event id per
        // detection (manual mode holds the event pending for a popup that
        // does not exist here). Without an id there is nothing for the false-
        // positive button to flip.
        savedAutoAdd = detector.autoAdd
        detector.autoAdd = true

        savedClubTypeName = detector.selectedClubTypeName
        detector.selectedClubTypeName = clubTypeName

        detector.testModeActive = true
        SupabaseUploader.shared.currentTestSessionId = id
        SupabaseUploader.shared.createTestSession(id: id)

        // Count detections off the same publisher the round UI uses, so the
        // counter cannot disagree with what the detector actually fired.
        detector.$lastDetectedSwing
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.onDetection() }
            .store(in: &cancellables)

        detector.startMonitoring()
        isRunning = true

        // A note set before Start was created without a session id; re-create
        // it now so its row points at this session.
        if !noteText.isEmpty { setNote(noteText) }

        ClientEventLogger.log("swingTest.start", detail: [
            "sessionId": .string(id.uuidString)
        ])
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        cancellables.removeAll()

        detector.stopMonitoring()
        detector.testModeActive = false
        SupabaseUploader.shared.flushPending()
        SupabaseUploader.shared.currentTestSessionId = nil

        if let savedAutoAdd { detector.autoAdd = savedAutoAdd }
        savedAutoAdd = nil
        if let savedClubTypeName { detector.selectedClubTypeName = savedClubTypeName }
        savedClubTypeName = nil
        activeNoteId = nil

        if let id = sessionId {
            SupabaseUploader.shared.endTestSession(
                id: id,
                detected: detectedCount,
                falsePositives: falsePositiveCount,
                lookbacks: lookbackCount
            )
            ClientEventLogger.log("swingTest.stop", detail: [
                "sessionId": .string(id.uuidString),
                "detected": .integer(detectedCount),
                "falsePositives": .integer(falsePositiveCount),
                "lookbacks": .integer(lookbackCount)
            ])
        }
        sessionId = nil
        // Anything still unmarked at stop stays positive/low — the user saw it
        // fire and chose not to flag it, which is the same signal a round gives.
        unmarkedEventIds.removeAll()
        markableCount = 0
    }

    // MARK: - Note

    /// Set or replace the active note. Empty clears it. Each non-empty value
    /// is its own row, so events link to exactly the text that was active.
    func setNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        noteText = trimmed
        guard !trimmed.isEmpty else { activeNoteId = nil; return }
        let id = UUID()
        activeNoteId = id
        SupabaseUploader.shared.createTestNote(id: id, sessionId: sessionId, text: trimmed)
    }

    // MARK: - Labeling

    private func onDetection() {
        detectedCount += 1
        lastEventAt = Date()
        justMarked = false
        // Published by the uploader on the auto-add path; consumed here so a
        // later detection can't reuse a stale id. A detection that produced no
        // id never reached `swing_events`, so there is nothing to mislabel and
        // nothing to push.
        if let eventId = detector.lastSwingEventId {
            unmarkedEventIds.append(eventId)
            markableCount = unmarkedEventIds.count
            if let noteId = activeNoteId {
                SupabaseUploader.shared.linkNote(noteId: noteId, kind: "swing_event", eventId: eventId)
            }
        }
        detector.lastSwingEventId = nil
    }

    /// It fired and it shouldn't have. Flips the event to false_positive/high.
    ///
    /// Unlike the round's undo button this is unambiguous: there is no stroke
    /// to remove and no practice-swing replacement sharing the label, so
    /// everything marked here is a genuine detector misfire.
    var canMarkFalsePositive: Bool { !unmarkedEventIds.isEmpty }

    /// Pops the most recent unmarked detection and flips it to
    /// false_positive/high. Press it once per bad detection; the stack walks
    /// backwards, so two that fired in a burst take two presses.
    func markLastFalsePositive() {
        guard let eventId = unmarkedEventIds.popLast() else { return }
        markableCount = unmarkedEventIds.count
        SupabaseUploader.shared.markFalsePositive(eventId: eventId)
        falsePositiveCount += 1
        justMarked = true
        WKInterfaceDevice.current().play(.failure)
        ClientEventLogger.log("swingTest.falsePositive", detail: [
            "eventId": .string(eventId.uuidString),
            "remainingMarkable": .integer(unmarkedEventIds.count)
        ])
    }

    /// You swung and nothing happened. Uploads the raw motion window.
    ///
    /// The window shrinks to cover only motion nothing has claimed yet, so
    /// pressing this after a detection captures just the swing since it, and
    /// pressing it twice in a row sends nothing the second time.
    @discardableResult
    func captureLookback() -> Bool {
        guard let capture = detector.captureLookbackWindow() else {
            WKInterfaceDevice.current().play(.failure)
            return false
        }
        // Count and confirm immediately; upload after the 800Hz batches
        // covering this window have landed. Batches arrive ~0.5s apart and the
        // press happens seconds after the stroke, so slicing right now stores a
        // window whose last moments — the impact — have not been delivered yet.
        lookbackCount += 1
        WKInterfaceDevice.current().play(.success)

        let sid = sessionId
        let club = detector.selectedClubTypeName
        let delay = detector.rawAccelSettleDelay
        let groupId = UUID()
        if let noteId = activeNoteId {
            SupabaseUploader.shared.linkNote(noteId: noteId, kind: "miss", eventId: groupId)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let settled = self.detector.rawAccelSlice(from: capture.windowStart,
                                                      to: capture.windowEnd)
            let raw = settled.count > capture.rawAccelSlice.count ? settled : capture.rawAccelSlice
            ClientEventLogger.log("lookback.raw.settled", detail: [
                "atCapture": .integer(capture.rawAccelSlice.count),
                "afterSettle": .integer(raw.count)
            ])
            SupabaseUploader.shared.uploadLookbackCapture(
                motionSlice: capture.motionSlice,
                rawAccelSlice: raw,
                rejections: capture.rejections,
                windowSeconds: capture.windowSeconds,
                roundId: nil,
                holeNumber: nil,
                clubType: club,
                testSessionId: sid,
                groupId: groupId
            )
        }
        return true
    }
}
