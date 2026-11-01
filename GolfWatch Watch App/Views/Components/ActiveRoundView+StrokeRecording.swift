import SwiftUI
import MapKit
import WatchKit

// MARK: - Stroke Recording
//
// Detected-swing → stroke flow: the swing overlay, auto-add / manual-add paths,
// penalty placement, hole finishing, and the aim-direction toggle. Everything
// that lives between "motion detector fired" and "stroke persisted to the round."
extension ActiveRoundView {
    func swingTypeColor(_ swing: SwingDetectionManager.DetectedSwing?) -> Color {
        guard let swing = swing else { return .cyan }
        switch swing.swingType {
        case .putt: return .cyan
        case .swing: return .orange
        }
    }

    func swingTypeLabel(_ swing: SwingDetectionManager.DetectedSwing?) -> String {
        guard let swing = swing else { return "" }
        switch swing.swingType {
        case .putt: return "PUTT"
        case .swing: return "SWING"
        }
    }

    @ViewBuilder
    func swingDetectedOverlay(buttonSize: CGFloat, iconSize: CGFloat) -> some View {
        // Auto-add path no longer shows a popup — strokes get added
        // immediately and the main-screen undo button is the affordance to
        // remove false positives. Only the manual-add (suggestion) flow
        // shows this overlay, where the user explicitly accepts (figure.golf)
        // or rejects (X). Both actions produce high-confidence labels.
        if let swing = swingDetector.lastDetectedSwing,
           !swingDetector.autoAdd,
           store.currentHole != nil && !isPlacingTarget {
            let typeColor = swingTypeColor(swing)
            VStack(spacing: 4) {
                // Main swing button — explicit accept (manual mode only).
                Button(action: addStrokeFromLastSwing) {
                    ZStack {
                        // Outer pulse ring for motion effect
                        Circle()
                            .stroke(typeColor.opacity(0.3), lineWidth: 2)
                            .frame(width: buttonSize * 1.7, height: buttonSize * 1.7)
                            .scaleEffect(isPulsing ? 1.18 : 0.92)
                            .opacity(isPulsing ? 0.0 : 0.8)
                            .animation(.easeOut(duration: 1.0).repeatForever(autoreverses: false),
                                       value: isPulsing)

                        if minimalScreenMode {
                            Circle()
                                .fill(Color.black.opacity(0.001))
                                .frame(width: buttonSize * 1.4, height: buttonSize * 1.4)

                            Circle()
                                .stroke(typeColor.opacity(0.95), lineWidth: 2.5)
                                .frame(width: buttonSize * 1.4, height: buttonSize * 1.4)
                                .shadow(color: typeColor.opacity(0.4), radius: 8, x: 0, y: 0)

                            Image(systemName: "figure.golf")
                                .font(.system(size: iconSize * 1.25, weight: .bold))
                                .foregroundColor(typeColor)
                                .rotationEffect(.degrees(-8))
                        } else {
                            Circle()
                                .fill(typeColor.opacity(0.7))
                                .frame(width: buttonSize * 1.5, height: buttonSize * 1.5)
                                .shadow(color: typeColor.opacity(0.4), radius: 8, x: 0, y: 0)

                            HStack(spacing: 2) {
                                ForEach(0..<3, id: \.self) { i in
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(Color.white.opacity(0.4 - Double(i) * 0.1))
                                        .frame(width: 2, height: CGFloat(8 - i * 2))
                                }
                                Spacer()
                            }
                            .frame(width: buttonSize * 1.2)
                            .offset(x: -iconSize * 0.3)

                            Image(systemName: "figure.golf")
                                .font(.system(size: iconSize * 1.4, weight: .bold))
                                .foregroundColor(.white)
                                .rotationEffect(.degrees(-8))
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .focusable(false)
                .onAppear {
                    isPulsing = true
                }
                .onDisappear {
                    isPulsing = false
                }

                // Dismiss button — explicit reject (manual mode only).
                // Flushes the pending swing_event as false_positive/high.
                Button(action: {
                    SupabaseUploader.shared.onSwingRejected()
                    swingDetector.clearLastSwing()
                    WKInterfaceDevice.current().play(.click)
                    isMainViewFocused = true
                    applyClubPrediction()
                }) {
                    ZStack {
                        if minimalScreenMode {
                            Circle()
                                .fill(Color.black.opacity(0.001))
                                .frame(width: buttonSize * 0.6, height: buttonSize * 0.6)

                            Circle()
                                .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
                                .frame(width: buttonSize * 0.6, height: buttonSize * 0.6)

                            Image(systemName: "xmark")
                                .font(.system(size: iconSize * 0.5, weight: .bold))
                                .foregroundColor(.white.opacity(0.9))
                        } else {
                            Circle()
                                .fill(Color.red.opacity(0.7))
                                .frame(width: buttonSize * 0.6, height: buttonSize * 0.6)

                            Image(systemName: "xmark")
                                .font(.system(size: iconSize * 0.5, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .focusable(false)

            }
            .offset(y: -15)
            .transition(.scale.combined(with: .opacity))
        }
    }

    func recordStroke() {
        // A manually-added stroke has no detected swing behind it, so there is
        // no heading to record. This used to write bearing-to-hole here, which
        // made Stroke.trajectoryHeading a restatement of the hole's position
        // rather than a measurement — any downstream "how far off line was I"
        // built on it was comparing bearing-to-hole against bearing-to-hole
        // and always came out at zero. Nil means unknown; never fabricate.
        guard let club = selectedClub else {
            dprint("⌚ [RecordStroke] ERROR: No club selected")
            return
        }
        let newStrokeId = store.addStroke(clubId: club.id, trajectoryHeading: nil)

        // False-negative capture group. Manual stroke add = user swung but
        // detector missed it. Capture ALL rejected shapes since the last
        // stroke as candidates of a false-negative GROUP — one of them is
        // the real missed swing, the rest are noise. Goes to
        // `false_negative_groups` + `false_negative_candidates`, NOT to
        // `swing_events` (those are only for high-confidence labeled data).
        // Will be manually sifted later to identify the actual missed swing.
        let rejected = swingDetector.claimAllRejectionsSinceLastStroke()
        if !rejected.isEmpty {
            SupabaseUploader.shared.uploadFalseNegativeGroup(
                rejections: rejected,
                roundId: store.currentRound?.id,
                strokeId: newStrokeId,
                holeNumber: store.currentHole?.number,
                clubType: swingDetector.selectedClubTypeName
            )
        }

        // Reset manual club override and immediately re-predict based on current distance
        manualClubOverride = false
        applyClubPrediction()

        // Haptic feedback
        WKInterfaceDevice.current().play(.success)
        isMainViewFocused = true

        // Visual feedback
        withAnimation(.easeInOut(duration: 0.3)) {
            showingRecordedFeedback = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.easeInOut(duration: 0.3)) {
                showingRecordedFeedback = false
            }
        }
    }

    func handleDoubleTapGesture() {
        // Manual-add: a pending suggestion is waiting in the popup → accept it.
        // Auto-add: no popup; double-tap just records a normal stroke (the
        // detector will already have added one if it fired). Undo is handled
        // by the main-screen button.
        if !swingDetector.autoAdd,
           swingDetector.lastDetectedSwing != nil,
           store.currentHole != nil {
            addStrokeFromLastSwing()
        } else {
            recordStroke()
        }
    }

    func addStrokeFromLastSwing() {
        guard let swing = swingDetector.lastDetectedSwing else {
            dprint("⌚ [AddLastSwing] No swing detected")
            return
        }

        guard store.currentRound != nil, store.currentHole != nil else {
            dprint("⌚ [AddLastSwing] No active round or hole")
            return
        }

        // Swing-derived launch bearing (from the detector's swing direction).
        // No bearing-to-hole fallback — that produced a number
        // indistinguishable from a real measurement while carrying no
        // information about where the ball actually went.
        let trajectoryHeading = swing.trajectoryHeading

        guard let club = selectedClub else {
            dprint("⌚ [RecordStrokeFromMotion] ERROR: No club selected")
            return
        }

        let strokeId = store.addStroke(
            clubId: club.id,
            trajectoryHeading: trajectoryHeading,
            coordinate: swing.location
        )

        if let strokeId = strokeId, let meta = swingDetector.lastDetectionMetadata {
            swingDetector.cacheDetectionMetadata(strokeId: strokeId, metadata: meta)
        }

        manualClubOverride = false
        applyClubPrediction()
        swingDetector.clearLastSwing()

        SupabaseUploader.shared.onSwingAccepted()

        WKInterfaceDevice.current().play(.success)
        isMainViewFocused = true

        dprint("⌚ [AddLastSwing] Added stroke from detected swing at \(swing.location) with \(swing.peakAcceleration)G")
    }

    /// Auto-add a stroke from the detected swing — no popup, fire and forget.
    /// Strokes get added immediately; the main-screen undo button is the
    /// affordance to remove false positives.
    /// When ignorePractice is ON and the swing type is not putt, replaces the
    /// previous auto-added stroke if the user hasn't moved (within
    /// ignorePracticeRadius yards). Practice replacement also flips the
    /// previous swing_event row to false_positive/high (same as undo) so the
    /// dropped stroke is correctly labeled in the training set.
    func autoAddStrokeFromSwing() {
        guard let swing = swingDetector.lastDetectedSwing else { return }
        guard store.currentRound != nil, let hole = store.currentHole else { return }
        guard !store.isHoleCompleted(hole.number) else { return }

        // Swing-derived only — see recordStrokeFromMotion for why there's no
        // bearing-to-hole fallback.
        let trajectoryHeading = swing.trajectoryHeading

        guard let club = selectedClub else { return }

        // Practice-swing replacement: delete the previous auto-added stroke
        // if user hasn't moved + same swing type. Its event is marked
        // positive/high with not_a_stroke_reason=practice — NOT false_positive.
        // The detector was right: that was a real golf swing, correctly
        // identified. It simply wasn't a shot that counts. Labeling it a false
        // positive trained the model against its own correct answers, and
        // because this path fires only on an unambiguous repeated swing in one
        // spot, those were the best positive samples the app had.
        if let last = autoAddStack.last,
           let prevLoc = lastAutoAddedLocation,
           swingDetector.shouldReplacePreviousStroke(
               newLocation: swing.location,
               previousLocation: prevLoc,
               swingType: swing.swingType
           ) {
            store.deleteLastStroke()
            SupabaseUploader.shared.markPracticeSwing(eventId: last.eventId)
            swingDetector.logUndoEvent(strokeId: last.strokeId)
            autoAddStack.removeLast()
            dprint("⌚ [AutoAdd] Replaced previous stroke (practice swing, same location)")
        }

        let strokeId = store.addStroke(
            clubId: club.id,
            trajectoryHeading: trajectoryHeading,
            coordinate: swing.location
        )

        if let strokeId = strokeId, let meta = swingDetector.lastDetectionMetadata {
            swingDetector.cacheDetectionMetadata(strokeId: strokeId, metadata: meta)
        }

        // Pair the new stroke with its swing_event id (set by the manager
        // after the synchronous upload). Without an event id we still record
        // the stroke — it just won't be flippable on undo.
        if let strokeId = strokeId, let eventId = swingDetector.lastSwingEventId {
            autoAddStack.append((strokeId: strokeId, eventId: eventId))
        }
        // Consume the published id so a later manual add doesn't reuse it.
        swingDetector.lastSwingEventId = nil

        manualClubOverride = false
        lastAutoAddedLocation = swing.location

        WKInterfaceDevice.current().play(.success)

        dprint("⌚ [AutoAdd] Auto-added stroke from detected swing at \(swing.location)")
    }

    /// Main-screen undo button: deletes the most recent stroke. If that
    /// stroke was auto-added (top of `autoAddStack`), also flips its
    /// swing_event row to false_positive/high. Manual strokes are deletable
    /// too — they just don't have an event row to label. Multi-undo: each
    /// tap removes one more, walking back through the auto-add stack as it
    /// goes.
    func undoLastStroke() {
        // Most recent stroke on this hole — INCLUDING penalty strokes, since
        // the undo button is a single backtrack affordance for both real
        // shots and penalty taps. `lastRealStroke` filters penalties out
        // for score-display reasons; we need the absolute last here.
        let lastId: UUID? = {
            guard let round = store.currentRound, let hole = store.currentHole else { return nil }
            return round.strokes
                .filter { $0.holeNumber == hole.number }
                .sorted { $0.strokeNumber > $1.strokeNumber }
                .first?.id
        }()
        guard let lastId = lastId else {
            // Nothing on this hole — fall back to store.deleteLastStroke()'s
            // "reopen previous hole" behavior so the button still feels
            // responsive when you're at the start of a fresh hole.
            store.deleteLastStroke()
            WKInterfaceDevice.current().play(.click)
            isMainViewFocused = true
            return
        }

        store.deleteLastStroke()

        if let idx = autoAddStack.lastIndex(where: { $0.strokeId == lastId }) {
            let entry = autoAddStack.remove(at: idx)
            SupabaseUploader.shared.markFalsePositive(eventId: entry.eventId)
            swingDetector.logUndoEvent(strokeId: entry.strokeId)
            dprint("⌚ [Undo] Undid auto-added stroke \(entry.strokeId) (false detection)")
        } else {
            dprint("⌚ [Undo] Undid manual stroke \(lastId)")
        }

        // Update the practice-replacement anchor so the next auto-add
        // doesn't compare against a stroke that no longer exists.
        lastAutoAddedLocation = autoAddStack.isEmpty ? nil : lastAutoAddedLocation

        WKInterfaceDevice.current().play(.click)
        isMainViewFocused = true
        applyClubPrediction()
    }

    func deleteLastStroke() {
        store.deleteLastStroke()

        // Haptic feedback
        WKInterfaceDevice.current().play(.click)
    }

    func finishCurrentHole() {
        // Check if this is the last hole before finishing
        let isLastHole = store.currentRound != nil && !store.hasNextHole

        store.finishCurrentHole()

        // Haptic feedback - directionUp for hole completion
        WKInterfaceDevice.current().play(.directionUp)

        // If this was the last hole, automatically add next hole (which will show flag placement)
        if isLastHole {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                store.addNextHole()
            }
        }
    }

    func handleDetectedSwingChange(_ newValue: Date?) {
        // Yardage-based putter auto-select kicks in ONLY when no green
        // polygon is available for the current hole. With a polygon, the
        // distance-to-polygon check (in `handleLocationChange` →
        // `isOnCurrentGreen` plus the dev-tunable margin ring) is the
        // sole driver — yardage is too crude when we know the actual
        // green geometry.
        if let swing = swingDetector.lastDetectedSwing,
           swing.swingType == .putt,
           swingDetector.puttAutoSelectYards > 0,
           swingDetector.selectedClubTypeName != "Putt",
           currentHoleGreenBlob == nil,
           let distance = distanceToHole,
           distance <= swingDetector.puttAutoSelectYards,
           let putterIndex = putterClubIndex() {
            ClientEventLogger.log("club.autoSelect.putter.yardageFallback", detail: [
                "distanceYd": .integer(distance),
                "thresholdYd": .integer(swingDetector.puttAutoSelectYards),
                "reason": .string("no green polygon for current hole — flag may be outside any OSM green")
            ])
            isAutoSelectingClub = true
            selectedClubIndex = Double(putterIndex)
            updateSwingDetectorClub()
            isAutoSelectingClub = false
        }

        if swingDetector.autoAdd, newValue != nil {
            autoAddStrokeFromSwing()
        }
    }
}
