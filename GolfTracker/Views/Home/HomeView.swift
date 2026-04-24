//
//  HomeView.swift
//  GolfTracker
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: DataStore
    @State private var showingClubManagement = false
    @State private var showingSettings = false

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                LocationPermissionBanner()

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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingClubManagement) {
                ClubManagementView()
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView().environmentObject(store)
            }
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(DataStore())
}
