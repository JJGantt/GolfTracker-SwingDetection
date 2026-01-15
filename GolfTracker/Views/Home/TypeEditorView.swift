//
//  TypeEditorView.swift
//  GolfTracker
//

import SwiftUI

struct TypeEditorView: View {
    @EnvironmentObject var store: DataStore
    @Environment(\.dismiss) var dismiss

    let typeId: UUID
    let onSelectClub: (UUID?) -> Void

    @State private var typeName: String = ""
    @State private var selectedClubId: UUID?
    @State private var showingAddClub = false
    @State private var editingClub: ClubData?

    init(typeId: UUID, activeClubId: UUID?, onSelectClub: @escaping (UUID?) -> Void) {
        self.typeId = typeId
        self.onSelectClub = onSelectClub
        _selectedClubId = State(initialValue: activeClubId)
    }

    var clubType: ClubTypeData? {
        store.clubTypes.first(where: { $0.id == typeId })
    }

    var clubsOfType: [ClubData] {
        store.getClubs(forType: typeId)
    }

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Type Name")) {
                    TextField("Type Name", text: $typeName)
                }

                Section(header: Text("Clubs (\(clubsOfType.count))")) {
                    Button(action: {
                        showingAddClub = true
                    }) {
                        Label("Add New Club", systemImage: "plus.circle.fill")
                    }

                    ForEach(clubsOfType) { club in
                        HStack(spacing: 12) {
                            Button(action: {
                                selectedClubId = club.id
                            }) {
                                Image(systemName: selectedClubId == club.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selectedClubId == club.id ? .green : .gray)
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)

                            Button(action: {
                                editingClub = club
                            }) {
                                HStack {
                                    Text(club.name)
                                        .font(.headline)
                                        .foregroundColor(.primary)

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .swipeActions(edge: .trailing) {
                            if !club.isDefault {
                                Button(role: .destructive) {
                                    if selectedClubId == club.id {
                                        selectedClubId = clubsOfType.first(where: { $0.id != club.id })?.id
                                    }
                                    store.deleteClub(club)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .onMove(perform: store.moveClub)
                }
            }
            .navigationTitle("Edit Type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveType()
                    }
                    .disabled(typeName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $showingAddClub) {
                ClubEditorView(club: nil, typeId: typeId)
                    .environmentObject(store)
            }
            .sheet(item: $editingClub) { club in
                ClubEditorView(club: club, typeId: typeId)
                    .environmentObject(store)
            }
            .onAppear {
                typeName = clubType?.name ?? ""
            }
        }
    }

    private func saveType() {
        let trimmedName = typeName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, let type = clubType else { return }

        store.updateClubType(type, name: trimmedName)
        onSelectClub(selectedClubId)
        dismiss()
    }
}

#Preview {
    TypeEditorView(typeId: UUID(), activeClubId: nil, onSelectClub: { _ in })
        .environmentObject(DataStore())
}
