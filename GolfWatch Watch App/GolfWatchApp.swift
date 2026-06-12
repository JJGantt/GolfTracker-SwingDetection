import SwiftUI
import SwiftData
import CoreMotion

/// Catch uncaught NSExceptions and persist a small record so the next
/// launch can emit an `app.crashed` event with the cause. We DO NOT
/// install signal handlers here — Swift signal-handler closures can't
/// safely allocate (Foundation calls / dictionaries / UserDefaults) and
/// the resulting handler-induced crash takes the app down on cold launch.
/// For signal-class crashes (SIGSEGV/SIGABRT/etc.) we rely on Apple's
/// own crash reports + the existing `sessionLive` UserDefaults flag.
private func installCrashHandlers() {
    NSSetUncaughtExceptionHandler { exc in
        let record: [String: Any] = [
            "kind": "exception",
            "name": exc.name.rawValue,
            "reason": exc.reason ?? "",
            "callStack": exc.callStackSymbols.prefix(30).joined(separator: "\n")
        ]
        UserDefaults.standard.set(record, forKey: "pendingCrashRecord")
        UserDefaults.standard.set(false, forKey: "sessionLive")
        UserDefaults.standard.synchronize()
    }
}

@main
struct GolfTrackerWatchApp: App {
    // These singletons manage their own lifetime — @ObservedObject is correct here.
    @ObservedObject private var connectivity = WatchConnectivityManager.shared
    private let locationManager = LocationManager.shared
    @ObservedObject private var swingDetector = SwingDetectionManager.shared
    @AppStorage("hasSeenWatchOnboarding") private var hasSeenWatchOnboarding = false
    @Environment(\.scenePhase) private var scenePhase

    /// Same SwiftData schema as the iOS app — Realtime sync from Supabase will
    /// populate this container with the user's rounds/clubs/etc.
    let modelContainer: ModelContainer = {
        let schema = Schema([
            Course.self, Hole.self, Round.self, Stroke.self, Target.self,
            ClubData.self, ClubTypeData.self, ClubSet.self
        ])
        do {
            return try ModelContainer(for: schema)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    init() {
        // Build-deploy marker. Bump the buildTag string here on any code
        // change you want to verify actually shipped to the watch — the
        // log row's `buildTag` will change accordingly. Use to confirm a
        // rebuild reached the device versus an old install lingering.
        ClientEventLogger.log("watch.build.launched", detail: [
            "buildTag": .string("crash-handler-rev2"),
            "compiledAt": .string("2026-05-03T13:15Z")
        ])

        // Crash-detection. Two layers because watchOS scenePhase fires
        // .background even on crash-induced terminations (so the
        // sessionLive flag is unreliable on its own — confirmed empirically).
        //
        // Layer 1: signal + uncaught-exception handlers. Write a small
        // crash record to UserDefaults synchronously when fatal — Mach
        // ports are already torn down so we can't talk to the network,
        // but UserDefaults survives. Replay it on next launch.
        // Layer 2: sessionLive flag (kept as belt-and-suspenders).
        let prevSessionId = UserDefaults.standard.string(forKey: "lastSessionId")
        let prevWasLive = UserDefaults.standard.bool(forKey: "sessionLive")
        let pendingCrash = UserDefaults.standard.dictionary(forKey: "pendingCrashRecord")
        let newSessionId = UUID().uuidString
        UserDefaults.standard.set(newSessionId, forKey: "lastSessionId")
        UserDefaults.standard.set(true, forKey: "sessionLive")
        UserDefaults.standard.removeObject(forKey: "pendingCrashRecord")
        ClientEventLogger.log("app.didLaunch", detail: [
            "sessionId": .string(newSessionId),
            "prevSessionId": prevSessionId.map { .string($0) } ?? .null,
            "prevSessionEndedGracefully": .bool(!prevWasLive)
        ])
        if let crash = pendingCrash {
            ClientEventLogger.log("app.crashed", detail: [
                "prevSessionId": prevSessionId.map { .string($0) } ?? .null,
                "kind": .string((crash["kind"] as? String) ?? "unknown"),
                "name": .string((crash["name"] as? String) ?? ""),
                "reason": .string((crash["reason"] as? String) ?? ""),
                "callStack": .string((crash["callStack"] as? String) ?? "")
            ])
        }
        installCrashHandlers()

        // configure() needs to happen before singletons access the container.
        WatchDataStore.shared.configure(container: modelContainer)
        RealtimeSync.shared.configure(container: modelContainer)
        // Realtime is round-scoped — ActiveRoundView starts/stops it.

        // Touch WalkieTalkie.shared so its init wires the inbound-audio +
        // talk-start callbacks on PlaygroupChannel before any round starts.
        _ = WalkieTalkie.shared
        // Cross-device GPS sim — subscribes to user_test_state and pushes
        // inbound coords into LocationManager so all GPS consumers respond
        // as if it were a real fix.
        Task { @MainActor in TestModeService.shared.start() }
    }

    var body: some Scene {
        WindowGroup {
            if !hasSeenWatchOnboarding {
                WatchOnboardingView(hasSeenWatchOnboarding: $hasSeenWatchOnboarding)
            } else if swingDetector.motionAuthStatus == .denied || swingDetector.motionAuthStatus == .restricted {
                MotionAuthDeniedView()
            } else {
                ContentView()
            }
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                swingDetector.checkAndRequestMotionAuthorization()
                // Finish any elevation fold-in that got cut off by an app
                // suspension at round end.
                Task { await ElevationFoldIn.retryPending() }
            } else if newPhase == .inactive || newPhase == .background {
                // Graceful exit — clear the live flag so next launch knows
                // the previous session ended cleanly.
                UserDefaults.standard.set(false, forKey: "sessionLive")
                ClientEventLogger.log("app.willResignActive", detail: [
                    "sessionId": .string(UserDefaults.standard.string(forKey: "lastSessionId") ?? "")
                ])
            }
        }
    }
}

struct MotionAuthDeniedView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.title2)

            Text("Motion Access Denied")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("Swing detection requires motion permission. On your iPhone go to Watch app > Privacy > Motion & Fitness and enable access.")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Button("Re-check") {
                SwingDetectionManager.shared.checkAndRequestMotionAuthorization()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding()
    }
}
