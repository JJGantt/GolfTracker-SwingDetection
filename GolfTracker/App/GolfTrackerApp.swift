//
//  GolfTrackerApp.swift
//  GolfTracker
//
//  Created by Jared gantt on 12/2/25.
//

import SwiftUI
import SwiftData

@main
struct GolfTrackerApp: App {
    // Use the shared singleton so other call sites (MultiplayerView, etc.)
    // see the same instance the view layer is bound to.
    @StateObject private var store = DataStore.shared
    @Environment(\.scenePhase) private var scenePhase

    /// SwiftData container is the persistence layer for all relational state
    /// (Course/Round/Stroke/Target/ClubData/ClubTypeData/ClubSet). Both the
    /// view layer (@Query) and the DataStore singleton read/write through it.
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
        dprint("🚀🚀🚀 APP LAUNCHED - GolfTracker is starting! 🚀🚀🚀")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .onAppear {
                    store.configure(container: modelContainer)
                    RealtimeSync.shared.configure(container: modelContainer)
                    // Realtime starts from AuthManager when a session is
                    // present (iOS keeps it always-on while signed in;
                    // watchOS narrows to round-scoped). Reconciliation on
                    // foreground happens via the scenePhase observer below.
                    // Touch WalkieTalkie.shared so its init wires the
                    // inbound-audio + talk-start callbacks on PlaygroupChannel.
                    _ = WalkieTalkie.shared
                    // Wire the cross-device GPS sim. Pulls user_test_state
                    // from Supabase and subscribes to changes; LocationManager
                    // applies inbound coords into its `location` property.
                    Task { @MainActor in TestModeService.shared.start() }
                }
                .onChange(of: scenePhase) { _, phase in
                    // Catch up on rounds rows we may have missed while
                    // backgrounded — Realtime postgres-changes don't replay.
                    if phase == .active {
                        Task { await RealtimeSync.shared.reconcileRoundsWithSupabase() }
                        // Finish any elevation fold-in that got cut off by
                        // an app suspension at round end.
                        Task { await ElevationFoldIn.retryPending() }
                    }
                }
        }
        .modelContainer(modelContainer)
    }
}
