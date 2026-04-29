//
//  ContentView.swift
//  GolfTracker
//
//  Created by Jared gantt on 12/2/25.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: DataStore
    @EnvironmentObject var motionDataHandler: MotionDataHandler
    @ObservedObject private var auth = AuthManager.shared
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

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
            }
        }
    }

    private var mainTabs: some View {
        TabView {
            StatsView()
                .tabItem {
                    Label("Stats", systemImage: "chart.bar.fill")
                }

            CourseListView(store: store)
                .tabItem {
                    Label("Courses", systemImage: "map")
                }

            RoundsHistoryView(store: store)
                .tabItem {
                    Label("Rounds", systemImage: "list.bullet.clipboard")
                }

            TestFilesView()
                .tabItem {
                    Label("Tests", systemImage: "waveform")
                }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(DataStore())
        .environmentObject(MotionDataHandler())
}
