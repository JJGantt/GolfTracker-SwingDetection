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
                Spacer()

                // Manage Clubs Button
                Button(action: {
                    showingClubManagement = true
                }) {
                    VStack(spacing: 12) {
                        Image(systemName: "figure.golf")
                            .font(.system(size: 60))
                        Text("Manage Clubs")
                            .font(.title2)
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(40)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(20)
                }
                .foregroundColor(.blue)
                .padding(.horizontal, 40)

                Spacer()
            }
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
