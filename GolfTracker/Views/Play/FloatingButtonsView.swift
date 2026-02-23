import SwiftUI
import CoreLocation

struct FloatingButtonsView: View {
    // State
    let hasLocation: Bool
    let hasActiveRound: Bool
    let isCurrentHoleCompleted: Bool
    let canUndo: Bool
    let aimArrowRotation: Double
    let isPlacingTarget: Bool

    // Actions
    let onFinishHole: () -> Void
    let onAddPenaltyStroke: () -> Void
    let onRecordStroke: () -> Void
    let onCaptureAimDirection: () -> Void
    let onToggleTargetPlacement: () -> Void
    let onUndo: () -> Void
    let onShowScorecard: () -> Void

    var body: some View {
        ZStack {
            // Right side buttons (bottom to top: stroke, penalty, finish)
            VStack {
                Spacer()
                VStack(spacing: 12) {
                    // Yellow button for finish hole (top)
                    Button(action: onFinishHole) {
                        Image(systemName: "flag.fill")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .frame(width: 60, height: 60)
                            .background(Color.yellow.opacity(0.95))
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                    }
                    .disabled(!hasActiveRound || isCurrentHoleCompleted)
                    .opacity((!hasActiveRound || isCurrentHoleCompleted) ? 0.3 : 0.95)

                    // Orange button for penalty stroke
                    Button(action: onAddPenaltyStroke) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .frame(width: 60, height: 60)
                            .background(Color.orange.opacity(0.95))
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                    }
                    .disabled(!hasActiveRound || isCurrentHoleCompleted)
                    .opacity((!hasActiveRound || isCurrentHoleCompleted) ? 0.3 : 0.95)

                    // Green button for new stroke (bottom)
                    Button(action: onRecordStroke) {
                        Image(systemName: "plus")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .frame(width: 60, height: 60)
                            .background(Color.green.opacity(0.95))
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                            .opacity((!hasLocation || !hasActiveRound) ? 0.5 : 0.95)
                    }
                    .disabled(!hasLocation || !hasActiveRound || isCurrentHoleCompleted)
                    .opacity((!hasLocation || !hasActiveRound || isCurrentHoleCompleted) ? 0.3 : 1.0)
                }
                .padding(.trailing, 20)
                .padding(.bottom, 200)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            // Left side buttons (bottom to top: undo, aim direction, target)
            VStack {
                Spacer()
                HStack {
                    VStack(spacing: 12) {
                        // Scorecard button (top)
                        Button(action: onShowScorecard) {
                            ZStack {
                                Circle()
                                    .fill(Color.white.opacity(0.95))
                                    .frame(width: 60, height: 60)
                                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                                Image(systemName: "list.clipboard")
                                    .font(.title2)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.black)
                            }
                        }

                        // Target button
                        Button(action: onToggleTargetPlacement) {
                            ZStack {
                                Circle()
                                    .fill(Color.white.opacity(0.95))
                                    .frame(width: 60, height: 60)
                                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)

                                if isPlacingTarget {
                                    Circle()
                                        .stroke(Color.yellow, lineWidth: 4)
                                        .frame(width: 60, height: 60)
                                }

                                Image(systemName: "scope")
                                    .font(.title2)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.black)
                            }
                        }

                        // Blue button for aim direction
                        Button(action: onCaptureAimDirection) {
                            ZStack {
                                Circle()
                                    .fill(Color.blue.opacity(0.95))
                                    .frame(width: 60, height: 60)
                                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)

                                Image(systemName: "location.north.fill")
                                    .font(.title2)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                                    .rotationEffect(.degrees(aimArrowRotation))
                            }
                        }
                        .disabled(!hasActiveRound || isCurrentHoleCompleted)
                        .opacity((!hasActiveRound || isCurrentHoleCompleted) ? 0.3 : 0.95)

                        // Undo button (bottom)
                        Button(action: onUndo) {
                            ZStack {
                                Circle()
                                    .fill(Color.red.opacity(0.95))
                                    .frame(width: 60, height: 60)
                                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)

                                Image(systemName: "arrow.uturn.backward")
                                    .font(.title2)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                            }
                        }
                        .disabled(!canUndo)
                        .opacity(canUndo ? 0.95 : 0.9)
                    }
                    .padding(.leading, 20)

                    Spacer()
                }
                .padding(.bottom, 200)
            }
        }
    }
}
