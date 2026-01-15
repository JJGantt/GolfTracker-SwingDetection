//
//  AddClubTypeView.swift
//  GolfTracker
//

import SwiftUI

struct AddClubTypeView: View {
    @EnvironmentObject var store: DataStore
    @Environment(\.dismiss) var dismiss

    let clubType: ClubTypeData?

    @State private var typeName: String = ""

    init(clubType: ClubTypeData? = nil) {
        self.clubType = clubType
    }

    private var isEditing: Bool {
        clubType != nil
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Club Type Details")) {
                    TextField("Type Name (e.g., Sand Wedge, 2-Iron)", text: $typeName)

                    Text("This type will be used to group clubs for statistics.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(isEditing ? "Edit Club Type" : "Add Club Type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(isEditing ? "Save" : "Add") {
                        saveClubType()
                    }
                    .disabled(typeName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                typeName = clubType?.name ?? ""
            }
        }
    }

    private func saveClubType() {
        let trimmedName = typeName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        if let existingType = clubType {
            store.updateClubType(existingType, name: trimmedName)
        } else {
            store.addClubType(name: trimmedName)
        }
        dismiss()
    }
}

#Preview {
    AddClubTypeView()
        .environmentObject(DataStore())
}
