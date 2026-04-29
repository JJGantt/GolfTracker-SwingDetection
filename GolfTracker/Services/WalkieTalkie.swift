import Foundation
import SwiftUI
import AVFoundation
#if os(watchOS)
import WatchKit
#endif
#if os(iOS)
import AudioToolbox
#endif

/// Push-to-talk walkie-talkie for the active playgroup. Three jobs:
///   1. On press: fire `talk_start` broadcast (instant pre-alert) then
///      start an `AVAudioRecorder` writing AAC into a temp .m4a file.
///   2. On release: stop the recorder, hand the file to PlaygroupChannel
///      to upload + insert the delivery row.
///   3. On inbound row: PlaygroupChannel downloads the blob and calls
///      back via `onIncomingAudio`; this service plays it through
///      `AVAudioPlayer`.
///
/// Audio settings: AAC mono @ 16kbps, 22.05kHz — telephone-quality, ~2KB/sec.
/// A 10s clip ends up ~20KB.
@MainActor
final class WalkieTalkie: NSObject, ObservableObject {
    static let shared = WalkieTalkie()

    @Published private(set) var isRecording = false
    @Published private(set) var isPlaying = false

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var recordingStartedAt: Date?
    private var recordingURL: URL?

    private override init() {
        super.init()
        // Wire ourselves into PlaygroupChannel so inbound audio gets played
        // and inbound talk_start fires haptic + sound. The closure capture is
        // intentional — PlaygroupChannel doesn't import AVFoundation.
        PlaygroupChannel.shared.onIncomingAudio = { [weak self] url in
            Task { @MainActor in self?.play(url: url) }
        }
        PlaygroupChannel.shared.onTalkStartReceived = { [weak self] _ in
            Task { @MainActor in self?.fireIncomingAlert() }
        }
    }

    // MARK: - Push-to-talk

    /// Press the talk button. Pre-alert goes out immediately so other
    /// watches start hapticking before the audio is even recorded.
    func startTalking() {
        guard !isRecording else { return }
        guard PlaygroupChannel.shared.activePlaygroupId != nil else { return }

        Task { await PlaygroupChannel.shared.broadcastTalkStart() }

        do {
            try configureSessionForRecord()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ptt_\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 22050.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 16000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.prepareToRecord()
            r.record()

            recorder = r
            recordingURL = url
            recordingStartedAt = Date()
            isRecording = true
        } catch {
            print("🎙️ [WalkieTalkie] start failed: \(error.localizedDescription)")
        }
    }

    /// Release the talk button. Finalize recording and hand off for upload.
    func stopTalking() {
        guard isRecording, let r = recorder, let url = recordingURL else { return }
        r.stop()
        let durationMs = Int((recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0) * 1000)
        recorder = nil
        recordingURL = nil
        recordingStartedAt = nil
        isRecording = false

        // Don't bother sending a near-empty clip (button taps).
        guard durationMs >= 250 else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        Task {
            await PlaygroupChannel.shared.sendVoiceMessage(localFile: url, durationMs: durationMs)
        }
    }

    // MARK: - Inbound playback

    private func play(url: URL) {
        do {
            try configureSessionForPlayback()
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            p.play()
            player = p
            isPlaying = true
        } catch {
            print("🎙️ [WalkieTalkie] play failed: \(error.localizedDescription)")
        }
    }

    private func fireIncomingAlert() {
        #if os(watchOS)
        WKInterfaceDevice.current().play(.notification)
        #else
        // Built-in short ding. 1007 = "Tweet" alert, audible without
        // requiring a custom asset.
        AudioServicesPlaySystemSound(1007)
        #endif
    }

    // MARK: - AVAudioSession

    private func configureSessionForRecord() throws {
        // Note: AVAudioSession is iOS/watchOS, not macOS — both targets we
        // build for have it.
        let session = AVAudioSession.sharedInstance()
        #if os(iOS)
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .duckOthers, .allowBluetoothA2DP])
        #else
        // watchOS: .defaultToSpeaker is unavailable; the watch decides
        // routing on its own (paired phone speaker, AirPods, watch speaker).
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.duckOthers])
        #endif
        try session.setActive(true)
    }

    private func configureSessionForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
    }
}

extension WalkieTalkie: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.player = nil
        }
    }
}

// MARK: - Push-to-talk button

/// Press-and-hold microphone button. Hidden when the user isn't currently
/// in a playgroup. Fires `WalkieTalkie.startTalking()` on press,
/// `stopTalking()` on release. Visual state pulses red while recording.
struct PTTButton: View {
    @ObservedObject private var walkie = WalkieTalkie.shared
    @ObservedObject private var playgroup = PlaygroupChannel.shared

    var body: some View {
        if playgroup.activePlaygroupId != nil {
            ZStack {
                Circle()
                    .fill(walkie.isRecording ? Color.red : Color.black.opacity(0.55))
                    .frame(width: 36, height: 36)
                    .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1.5))
                Image(systemName: walkie.isRecording ? "waveform" : "mic.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !walkie.isRecording { walkie.startTalking() }
                    }
                    .onEnded { _ in
                        walkie.stopTalking()
                    }
            )
            .accessibilityLabel("Push to talk")
        }
    }
}

/// Menu-row variant of the PTT button — same press-and-hold semantics as
/// `PTTButton`, but styled as a full-width row so it slots into the watch
/// Options pull-up alongside Undo/Penalty/Home. Disabled (greyed) when not
/// in a playgroup so the row layout doesn't jump around between solo and
/// multiplayer rounds.
struct OptionsTalkButton: View {
    @ObservedObject private var walkie = WalkieTalkie.shared
    @ObservedObject private var playgroup = PlaygroupChannel.shared

    var body: some View {
        let inPlaygroup = playgroup.activePlaygroupId != nil
        HStack(spacing: 8) {
            Image(systemName: walkie.isRecording ? "waveform" : "mic.fill")
                .font(.system(size: 16, weight: .bold))
            Text(walkie.isRecording ? "Talking" : "Talk")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background((walkie.isRecording ? Color.red : Color.blue).opacity(inPlaygroup ? 0.9 : 0.4))
        .cornerRadius(8)
        .opacity(inPlaygroup ? 1.0 : 0.6)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard inPlaygroup else { return }
                    if !walkie.isRecording { walkie.startTalking() }
                }
                .onEnded { _ in
                    guard inPlaygroup else { return }
                    walkie.stopTalking()
                }
        )
    }
}

/// "Alex is talking…" banner driven by inbound `talk_start` broadcasts.
struct TalkingBanner: View {
    @ObservedObject private var playgroup = PlaygroupChannel.shared

    var body: some View {
        if let speakerId = playgroup.currentlySpeaking {
            let color = Color(hex: playgroup.color(for: speakerId))
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text("Talking…")
                    .font(.caption2.bold())
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.6)))
        }
    }
}
