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
    @State private var noteDraft = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if session.isRunning {
                    counters
                    liveReadout
                    // Hidden while farming, since nothing reaches the stack
                    // for it to mark — but kept whenever the stack is
                    // non-empty, so detections from before the toggle stay
                    // markable.
                    if !session.farmFalsePositives || session.canMarkFalsePositive {
                        falsePositiveButton
                    }
                    lookbackButton
                }
                startStopButton
                farmToggle
                clubPicker
                noteField
                // Which build is on the wrist. The watch app installs
                // asynchronously after the phone's and can lag well behind, so
                // without this it is not knowable from here whether a fix under
                // test is actually present.
                Text("build \(WatchConnectivityManager.localBuild)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
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

    // MARK: - Farm mode

    /// Every detection auto-marked a false positive. For sessions where a
    /// swing is impossible and so every detection is one — see
    /// `SwingTestSession.farmFalsePositives`.
    private var farmToggle: some View {
        Toggle("Farm FP", isOn: $session.farmFalsePositives)
            .font(.system(size: 13, weight: .semibold))
            .tint(.red)
    }

    // MARK: - Club + note (both optional)

    private static let noClub = "—"

    /// Optional. Written to `club_type` on every row the session produces;
    /// unselected stays null. Changeable mid-session.
    private var clubPicker: some View {
        Picker("Club", selection: Binding(
            get: { session.clubTypeName ?? Self.noClub },
            set: { session.clubTypeName = ($0 == Self.noClub) ? nil : $0 }
        )) {
            Text(Self.noClub).tag(Self.noClub)
            ForEach(WatchDataStore.shared.clubTypes.map(\.name), id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.navigationLink)
    }

    /// Optional. Persistent for the session; every event saved while it is set
    /// is linked to it. Empty clears it.
    private var noteField: some View {
        // Committed on submit, not per keystroke — each committed value is its
        // own note row, and a row per character would be nonsense.
        TextField("Note", text: $noteDraft)
            .textInputAutocapitalization(.sentences)
            .onSubmit { session.setNote(noteDraft) }
            .onAppear { noteDraft = session.noteText }
    }

    // MARK: - Counters

    private var counters: some View {
        HStack(spacing: 6) {
            counter(value: session.truePositiveCount, label: "HIT", color: .green)
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
        // 1Hz tick so the 800Hz down-counter advances and the rejection count
        // stays current (neither is @Published-driven at the cadence needed).
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 4) {
                Circle()
                    .fill(detector.isMonitoring ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)
                Text("pending \(detector.pendingRejectionCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                raw800Label
                if let club = detector.selectedClubTypeName {
                    Text("· \(club)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    /// 800Hz stream state: green = running and delivering, red + seconds =
    /// running but gone silent (and for how long; the watchdog is restarting
    /// it), dim = not running (no workout session yet).
    private var raw800Label: some View {
        let (color, text): (Color, String) = {
            switch detector.raw800State {
            case .live: return (.green, "800")
            case .off:  return (Color.white.opacity(0.3), "800")
            case .down:
                let secs = detector.raw800DownSince.map { Int(-$0.timeIntervalSinceNow) } ?? 0
                return (.red, "800 ↓\(secs)s")
            }
        }()
        return Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(color)
    }

    // MARK: - Buttons

    private var falsePositiveButton: some View {
        Button(action: { session.markLastFalsePositive() }) {
            HStack(spacing: 6) {
                Image(systemName: session.justMarked && !session.canMarkFalsePositive
                      ? "checkmark" : "xmark.circle.fill")
                Text("False Positive")
                    .font(.system(size: 14, weight: .semibold))
                // Depth of the unmarked stack, so a burst of detections shows
                // how many presses are still available instead of leaving it
                // to be guessed.
                if session.markableCount > 1 {
                    Text("\(session.markableCount)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.25)))
                }
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
