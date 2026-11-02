import SwiftUI
import WatchKit

// MARK: - Button Column
//
// The action buttons down the side of the round screen and the swipe-up
// handle that opens Options.
extension ActiveRoundView {
    @ViewBuilder
    func buttonsOverlay(buttonSize: CGFloat, iconSize: CGFloat) -> some View {
        VStack {
            Spacer()

            HStack(alignment: .bottom, spacing: 4) {
                // Left: Undo button — replaces the target button (target is
                // now in the pull-up Options menu). Standard undo arrow,
                // always red filled, white icon. Tap shows a confirmation
                // popup; confirming pops the most recent stroke. If that
                // stroke was auto-added, also flips its swing_event row to
                // false_positive/high (multi-tap = walk back through the
                // stack). Manual strokes are deletable too — they just
                // don't have an event to label. While target placement is
                // active, this slot becomes a "Done" button so the user
                // can exit target mode.
                VStack(spacing: 4) {
                    if store.currentHole != nil {
                        if isPlacingTarget {
                            Button(action: toggleTargetPlacement) {
                                ZStack {
                                    Circle()
                                        .fill(Color.yellow.opacity(0.95))
                                        .frame(width: buttonSize, height: buttonSize)
                                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

                                    Image(systemName: "checkmark")
                                        .font(.system(size: iconSize, weight: .bold))
                                        .foregroundColor(.black)
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                            .focusable(false)
                        } else {
                            Button(action: { showingUndoConfirmation = true }) {
                                ZStack {
                                    Circle()
                                        .fill(Color.red.opacity(canUndo ? 0.95 : 0.35))
                                        .frame(width: buttonSize, height: buttonSize)
                                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

                                    Image(systemName: "arrow.uturn.backward")
                                        .font(.system(size: iconSize, weight: .bold))
                                        .foregroundColor(.white)
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                            .focusable(false)
                            .disabled(!canUndo)
                        }
                    }
                }

                Spacer()

                // Right side column
                VStack(spacing: 4) {
                    // watchOS 10: Club selector above the buttons
                    if #unavailable(watchOS 11.0) {
                        if !clubs.isEmpty {
                            legacyClubSelector(buttonSize: buttonSize)
                        }
                    }

                    // Dev data zone — only visible when debug logging is on.
                    // Three lines, no labels (developer reads by position):
                    //   1. steps since last detected swing
                    //   2. false-negative shapes buffered since last stroke
                    //      (these are the rejected paired-shape candidates
                    //      that would upload as a false_negative_group on
                    //      the next manual stroke add)
                    //   3. relative altimeter reading in cm (signed)
                    // Sits above the scorecard button. TimelineView at 1Hz
                    // polls all three values; the rejection buffer isn't
                    // @Published so polling is how the pill stays current.
                    if ClientEventLogger.enabled {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let altCm: Int? = LocationManager.shared.currentRelativeAltitudeMeters.map {
                                Int(($0 * 100).rounded())
                            }
                            VStack(alignment: .center, spacing: 1) {
                                Text("\(swingDetector.stepsSinceLastDetectedSwing)")
                                Text("\(swingDetector.rejectedShapesSinceLastStroke.count)")
                                Text(altCm.map { String(format: "%+d", $0) } ?? "—")
                            }
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(minWidth: 30)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.black.opacity(0.6))
                            )
                        }
                    }

                    // Scorecard button — opens the shared ScorecardView as a sheet.
                    // Sized to match the green plus below it; sits right above it.
                    Button(action: { showingScorecard = true }) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.85))
                                .frame(width: buttonSize * 0.7, height: buttonSize * 0.7)
                                .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                            Image(systemName: "list.number")
                                .font(.system(size: iconSize * 0.7, weight: .semibold))
                                .foregroundColor(.black)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .focusable(false)
                    .opacity(isPlacingTarget ? 0 : 0.95)

                    // Stroke button
                    VStack(spacing: 4) {
                        // Green stroke button - always show
                        Button(action: recordStroke) {
                            ZStack {
                                if minimalScreenMode {
                                    Circle()
                                        .fill(Color.black.opacity(0.001))
                                        .frame(width: buttonSize, height: buttonSize)

                                    Circle()
                                        .stroke(Color.green.opacity(0.95), lineWidth: 2)
                                        .frame(width: buttonSize, height: buttonSize)
                                        .shadow(
                                            color: Color.green.opacity(showingRecordedFeedback ? 0.45 : 0.25),
                                            radius: showingRecordedFeedback ? 4 : 2,
                                            x: 0,
                                            y: 0
                                        )

                                    Image(systemName: showingRecordedFeedback ? "checkmark" : "plus")
                                        .font(.system(size: iconSize, weight: .bold))
                                        .foregroundColor(.green)
                                } else {
                                    Circle()
                                        .fill(showingRecordedFeedback ? Color.white.opacity(0.95) : Color.green.opacity(0.95))
                                        .frame(width: buttonSize, height: buttonSize)
                                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

                                    Image(systemName: showingRecordedFeedback ? "checkmark" : "plus")
                                        .font(.system(size: iconSize, weight: .bold))
                                        .foregroundColor(showingRecordedFeedback ? .green : .white)
                                }
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .focusable(false)
                        .disabled(store.currentHole.map { store.isHoleCompleted($0.number) } ?? false)
                        .opacity(store.currentHole.map { store.isHoleCompleted($0.number) } ?? false ? 0.3 : 0.95)
                    }
                }
                .opacity(isPlacingTarget ? 0 : 1)
            }
            .padding(.horizontal, 4)
            .modifier(ButtonsBottomPaddingModifier())
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    var swipeUpIndicator: some View {
        VStack {
            Spacer()

            HStack {
                Spacer()

                // Swipe indicator pill
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color.white.opacity(0.5))
                    .frame(width: 30, height: 5)
                    .padding(.bottom, 4)
                    .onTapGesture {
                        showingOptions = true
                    }

                Spacer()
            }
        }
        .ignoresSafeArea()
        .opacity(isPlacingTarget ? 0 : 1)
    }
}
