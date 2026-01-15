//
//  ClubEditorView.swift
//  GolfTracker
//

import SwiftUI

struct ClubEditorView: View {
    @EnvironmentObject var store: DataStore
    @Environment(\.dismiss) var dismiss

    let club: ClubData?
    let typeId: UUID

    @State private var clubName: String = ""

    init(club: ClubData? = nil, typeId: UUID) {
        self.club = club
        self.typeId = typeId
    }

    private var isEditing: Bool {
        club != nil
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Club Name")) {
                    TextField("Club Name (e.g., TaylorMade SIM2)", text: $clubName)
                }
            }
            .navigationTitle(isEditing ? "Edit Club" : "Add Club")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(isEditing ? "Save" : "Add") {
                        saveClub()
                    }
                    .disabled(clubName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                clubName = club?.name ?? ""
            }
        }
    }

    private func saveClub() {
        let trimmedName = clubName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        if let existingClub = club {
            store.updateClub(existingClub, name: trimmedName, clubTypeId: typeId)
        } else {
            store.addCustomClub(name: trimmedName, clubTypeId: typeId)
        }
        dismiss()
    }
}

#Preview {
    ClubEditorView(typeId: UUID())
        .environmentObject(DataStore())
}
