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

    var body: some View {
        TabView {
            CourseListView(store: store)
                .tabItem {
                    Label("Courses", systemImage: "map")
                }

            RoundsHistoryView(store: store)
                .tabItem {
                    Label("History", systemImage: "clock")
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
