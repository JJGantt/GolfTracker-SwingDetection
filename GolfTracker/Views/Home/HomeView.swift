//
//  HomeView.swift
//  GolfTracker
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: DataStore
    @State private var showingClubManagement = false

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Manage Clubs Button
                Button(action: {
                    showingClubManagement = true
                }) {
                    Label("Manage Clubs", systemImage: "figure.golf")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Spacer()
            }
            .padding()
            .navigationTitle("Home")
            .sheet(isPresented: $showingClubManagement) {
                ClubManagementView()
            }
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(DataStore())
}
