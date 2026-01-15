//
//  ClubSetEditorView.swift
//  GolfTracker
//

import SwiftUI

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

struct ClubSetEditorView: View {
    @EnvironmentObject var store: DataStore
    @Environment(\.dismiss) var dismiss

    let clubSet: ClubSet?

    @State private var setName: String = ""
    @State private var typeSelections: [TypeSelection] = []
    @State private var showingAddType = false
    @State private var editingTypeId: UUID?

    init(clubSet: ClubSet? = nil) {
        self.clubSet = clubSet
    }

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Set Name")) {
                    TextField("Set Name", text: $setName)
                }

                Section(header: Text("Club Types (\(typeSelections.count) selected)")) {
                    Button(action: {
                        showingAddType = true
                    }) {
                        Label("Add New Type", systemImage: "plus.circle.fill")
                    }

                    ForEach(store.clubTypes) { clubType in
                        let isSelected = typeSelections.contains(where: { $0.typeId == clubType.id })
                        let activeClub = typeSelections.first(where: { $0.typeId == clubType.id })
                            .flatMap { $0.activeClubId }
                            .flatMap { store.getClub(byId: $0) }

                        HStack(spacing: 12) {
                            Button(action: {
                                if isSelected {
                                    if typeSelections.count > 1 {
                                        typeSelections.removeAll { $0.typeId == clubType.id }
                                    }
                                } else {
                                    let defaultClub = store.getClubs(forType: clubType.id).first
                                    typeSelections.append(TypeSelection(typeId: clubType.id, activeClubId: defaultClub?.id))
                                }
                            }) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(isSelected ? .green : .gray)
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)

                            Button(action: {
                                editingTypeId = clubType.id
                            }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(clubType.name)
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                        if let club = activeClub {
                                            Text(club.name)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        } else {
                                            Text("No club selected")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .swipeActions(edge: .trailing) {
                            if !clubType.isDefault {
                                Button(role: .destructive) {
                                    typeSelections.removeAll { $0.typeId == clubType.id }
                                    store.deleteClubType(clubType)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .onMove(perform: store.moveClubType)
                }
            }
            .navigationTitle(clubSet == nil ? "New Club Set" : "Edit Club Set")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveClubSet()
                    }
                    .disabled(setName.trimmingCharacters(in: .whitespaces).isEmpty || typeSelections.isEmpty)
                }
            }
            .sheet(isPresented: $showingAddType) {
                AddClubTypeView()
                    .environmentObject(store)
            }
            .sheet(item: $editingTypeId) { typeId in
                TypeEditorView(
                    typeId: typeId,
                    activeClubId: typeSelections.first(where: { $0.typeId == typeId })?.activeClubId,
                    onSelectClub: { clubId in
                        if let index = typeSelections.firstIndex(where: { $0.typeId == typeId }) {
                            typeSelections[index].activeClubId = clubId
                        }
                    }
                )
                .environmentObject(store)
            }
            .onAppear {
                setName = clubSet?.name ?? ""
                typeSelections = clubSet?.typeSelections ?? []
            }
        }
    }

    private func saveClubSet() {
        let trimmedName = setName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        if let existingSet = clubSet {
            store.updateClubSet(existingSet, name: trimmedName, typeSelections: typeSelections)
        } else {
            // Creating a new set - create clubs named after the set for each type
            var newTypeSelections: [TypeSelection] = []
            for selection in typeSelections {
                let newClubId = store.addCustomClubReturningId(name: trimmedName, clubTypeId: selection.typeId)
                newTypeSelections.append(TypeSelection(typeId: selection.typeId, activeClubId: newClubId))
            }
            store.addClubSet(name: trimmedName, typeSelections: newTypeSelections)
        }

        dismiss()
    }
}

#Preview {
    ClubSetEditorView()
        .environmentObject(DataStore())
}
