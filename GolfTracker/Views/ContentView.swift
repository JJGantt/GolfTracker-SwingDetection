//
//  ContentView.swift
//  GolfTracker
//
//  Created by Jared gantt on 12/2/25.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: DataStore
    @ObservedObject private var auth = AuthManager.shared
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    /// nil = profile not yet checked for the current session.
    /// true = checked and the user has no usable name → show name prompt.
    /// false = checked and name is set → proceed normally.
    @State private var needsName: Bool? = nil

    var body: some View {
        Group {
            if !auth.isSignedIn {
                LoginView(onSignedIn: {})
            } else {
                mainTabs
                    .fullScreenCover(isPresented: Binding(
                        get: { !hasSeenOnboarding },
                        set: { if !$0 { hasSeenOnboarding = true } }
                    )) {
                        OnboardingView(hasSeenOnboarding: $hasSeenOnboarding)
                    }
                    .fullScreenCover(isPresented: Binding(
                        get: { hasSeenOnboarding && needsName == true },
                        set: { if !$0 { needsName = false } }
                    )) {
                        NameEditView(
                            title: "What should we call you?",
                            initial: "",
                            prompt: "Pick a name for your playgroup partners to see. You can change it later in Settings.",
                            allowCancel: false
                        ) { newName in
                            try await PlaygroupService.shared.upsertMyProfile(firstName: nil, displayName: newName)
                            await MainActor.run { needsName = false }
                        }
                    }
                    .task(id: auth.currentUserId) {
                        await checkProfileName()
                    }
            }
        }
    }

    private func checkProfileName() async {
        guard auth.isSignedIn else {
            needsName = nil
            return
        }
        // Apple ships fullName only on the very first SIWA, and only when the
        // user grants it. Anyone signing in without a name from Apple, or any
        // legacy account that signed in before profile capture existed, lands
        // here with both columns blank — prompt them once so multiplayer
        // shows a real name instead of "Player".
        let profile = try? await PlaygroupService.shared.myProfile()
        let resolved = (profile?.displayName ?? profile?.firstName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        await MainActor.run { needsName = resolved.isEmpty }
    }

    enum Tab: String { case stats, play, history, settings }

    /// The selected tab, kept for the window. Unbound, the tab view fell back
    /// to its first tab (Stats) whenever it was rebuilt, which happened as a
    /// round started or ended.
    @SceneStorage("selectedTab") private var selectedTab: Tab = .stats

    private var mainTabs: some View {
        TabView(selection: $selectedTab) {
            StatsView()
                .tabItem {
                    Label("Stats", systemImage: "chart.bar.fill")
                }
                .tag(Tab.stats)

            PlayTabView()
                .tabItem {
                    Label("Play", systemImage: "figure.golf")
                }
                .tag(Tab.play)

            RoundsHistoryView(store: store)
                .tabItem {
                    Label("History", systemImage: "list.bullet.clipboard")
                }
                .tag(Tab.history)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(Tab.settings)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(DataStore())
}
