//
//  ClubManagementView.swift
//  GolfTracker
//

import SwiftUI

struct ClubManagementView: View {
    @EnvironmentObject var store: DataStore
    @Environment(\.dismiss) var dismiss
    @State private var showingNewClubSet = false
    @State private var editingClubSet: ClubSet?

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Club Sets")) {
                    Button(action: {
                        showingNewClubSet = true
                    }) {
                        Label("New Club Set", systemImage: "plus.circle.fill")
                    }

                    if store.clubSets.isEmpty {
                        Text("No club sets yet. Create one to get started!")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    } else {
                        ForEach(store.clubSets) { clubSet in
                            HStack(spacing: 12) {
                                Button(action: {
                                    if !clubSet.isActive {
                                        store.setActiveClubSet(clubSet)
                                    }
                                }) {
                                    Image(systemName: clubSet.isActive ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(clubSet.isActive ? .green : .gray)
                                        .font(.title3)
                                }
                                .buttonStyle(.plain)

                                Button(action: {
                                    editingClubSet = clubSet
                                }) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(clubSet.name)
                                                .font(.headline)
                                                .foregroundColor(.primary)

                                            let typeNames = clubSet.typeSelections.compactMap { selection in
                                                store.getClubType(byId: selection.typeId)?.name
                                            }.prefix(3).joined(separator: ", ")
                                            let moreTypes = clubSet.typeSelections.count > 3 ? " +\(clubSet.typeSelections.count - 3) more" : ""

                                            Text(typeNames + moreTypes)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
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
                                Button(role: .destructive) {
                                    store.deleteClubSet(clubSet)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Club Sets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingNewClubSet) {
                ClubSetEditorView(clubSet: nil)
                    .environmentObject(store)
            }
            .sheet(item: $editingClubSet) { clubSet in
                ClubSetEditorView(clubSet: clubSet)
                    .environmentObject(store)
            }
        }
    }
}

#Preview {
    ClubManagementView()
        .environmentObject(DataStore())
}
