import SwiftUI
import WatchKit

/// Swing Test Mode screen. Reached from the watch home screen when the
/// iPhone's Settings → Developer toggle is on.
///
/// The layout is built around what you can actually read mid-swing, at arm's
/// length, without stopping: three counters at the top and two large buttons
/// underneath. Detections need no interaction — the wrist buzzes and the count
/// goes up — so both buttons are for the cases where the detector was wrong.
struct SwingTestView: View {
    @StateObject private var session = SwingTestSession.shared
    @StateObject private var detector = SwingDetectionManager.shared
    @Environment(\.dismiss) private var dismiss

    /// Brief confirmation after a lookback so the press is visibly acknowledged
    /// even when the upload itself is still in flight.
    @State private var lookbackFlash = false
    @State private var lookbackFailed = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if session.isRunning {
                    counters
                    liveReadout
                    falsePositiveButton
                    lookbackButton
                }
                startStopButton
                if !session.isRunning {
                    Text("Runs the detector with no round. Swing, watch the count, and label only what it gets wrong.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Swing Test")
        .onDisappear {
            // Leaving the screen ends the session — the detector holds a
            // workout session and an extended runtime session, and neither
            // should outlive the UI that started them.
            if session.isRunning { session.stop() }
        }
    }

    // MARK: - Counters

    private var counters: some View {
        HStack(spacing: 6) {
            counter(value: session.detectedCount, label: "HIT", color: .green)
            counter(value: session.falsePositiveCount, label: "FP", color: .red)
            counter(value: session.lookbackCount, label: "MISS", color: .orange)
        }
    }

    private func counter(value: Int, label: String, color: Color) -> some View {
        VStack(spacing: 0) {
            Text("\(value)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
    }

    /// Live detector state. `pending` is the count of paired shapes the
    /// post-pairing gates rejected and haven't been claimed yet — when a swing
    /// vanishes, a non-zero value here means it paired and a gate killed it,
    /// and a zero means it never paired at all. That distinction is the first
    /// question to ask about any miss, so it belongs on screen rather than in
    /// a log.
    private var liveReadout: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(detector.isMonitoring ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
            Text("pending \(detector.rejectedShapesSinceLastStroke.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            if let club = detector.selectedClubTypeName {
                Text("· \(club)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Buttons

    private var falsePositiveButton: some View {
        Button(action: { session.markLastFalsePositive() }) {
            HStack(spacing: 6) {
                Image(systemName: session.lastMarkedFalsePositive ? "checkmark" : "xmark.circle.fill")
                Text(session.lastMarkedFalsePositive ? "Marked" : "False Positive")
                    .font(.system(size: 14, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(session.canMarkFalsePositive ? Color.red.opacity(0.85)
                                                     : Color.gray.opacity(0.3))
            .foregroundColor(.white)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .disabled(!session.canMarkFalsePositive)
    }

    private var lookbackButton: some View {
        Button(action: {
            let ok = session.captureLookback()
            lookbackFailed = !ok
            lookbackFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                lookbackFlash = false
                lookbackFailed = false
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: lookbackFlash
                      ? (lookbackFailed ? "exclamationmark.triangle.fill" : "checkmark")
                      : "arrow.counterclockwise.circle.fill")
                Text(lookbackFlash
                     ? (lookbackFailed ? "Nothing new" : "Captured")
                     : "Missed It")
                    .font(.system(size: 14, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.orange.opacity(0.85))
            .foregroundColor(.white)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    private var startStopButton: some View {
        Button(action: {
            if session.isRunning { session.stop() } else { session.start() }
        }) {
            Text(session.isRunning ? "Stop" : "Start")
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(session.isRunning ? Color.red : Color.green)
                .foregroundColor(.white)
                .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    SwingTestView()
}
