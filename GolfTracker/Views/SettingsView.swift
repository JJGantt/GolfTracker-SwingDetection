import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: DataStore
    @ObservedObject private var auth = AuthManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showingSignOutConfirm = false
    @State private var showingDeleteConfirm = false
    @State private var isDeleting = false
    @State private var deleteError: String?
    @AppStorage(PlaygroupChannel.liveDotsEnabledKey) private var liveDotsEnabled = true

    @State private var displayName: String = ""
    @State private var savingName = false
    @State private var nameSavedMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if let uid = auth.currentUserId {
                        LabeledContent("User ID") {
                            Text(uid.prefix(8) + "…")
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Text("Display name")
                        Spacer()
                        TextField("First name", text: $displayName)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.words)
                            .onSubmit { saveName() }
                    }
                    Button {
                        saveName()
                    } label: {
                        if savingName {
                            HStack { ProgressView(); Text("Saving…") }
                        } else {
                            Text("Save name")
                        }
                    }
                    .disabled(savingName || displayName.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let msg = nameSavedMessage {
                        Text(msg).font(.caption).foregroundColor(.secondary)
                    }

                    Button("Sign Out") {
                        showingSignOutConfirm = true
                    }
                }

                Section("Data") {
                    Button(role: .destructive) {
                        showingDeleteConfirm = true
                    } label: {
                        if isDeleting {
                            HStack { ProgressView(); Text("Deleting…") }
                        } else {
                            Text("Delete My Data")
                        }
                    }
                    .disabled(isDeleting)

                    if let err = deleteError {
                        Text(err).font(.caption).foregroundColor(.red)
                    }

                    Text("Removes every record tied to your account on the server (rounds, courses, strokes, clubs). Anonymized motion data is not deleted. See Privacy Policy for details.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Multiplayer") {
                    NavigationLink {
                        MultiplayerView()
                    } label: {
                        Label("Host or join a round", systemImage: "person.2.fill")
                    }
                    Toggle("Share my live position", isOn: $liveDotsEnabled)
                    Text("When on, your playgroup partners see a moving dot for you on the map. Other players' dots are still visible to you either way.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Credits") {
                    Link(destination: URL(string: "https://www.openstreetmap.org/copyright")!) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Map data © OpenStreetMap contributors")
                            Text("Course geometry sourced from OpenStreetMap (ODbL)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                // Pre-fill the name field with whatever's saved (display_name
                // override beats SIWA-captured first_name).
                if let p = try? await PlaygroupService.shared.myProfile() {
                    let pre = p.displayName ?? p.firstName ?? ""
                    if displayName.isEmpty { displayName = pre }
                }
            }
            .confirmationDialog("Sign out?", isPresented: $showingSignOutConfirm, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    auth.signOut()
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Your local data stays on this device. Signing back in restores access to your server data.")
            }
            .confirmationDialog("Delete all your data?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
                Button("Delete Everything", role: .destructive) { performDelete() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This permanently removes your rounds, courses, strokes, and clubs from the server. This cannot be undone.")
            }
        }
    }

    private func saveName() {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        savingName = true
        nameSavedMessage = nil
        Task {
            do {
                // We store the user-typed value in `display_name` (the
                // explicit override slot) so it always wins over any
                // first_name SIWA captured.
                try await PlaygroupService.shared.upsertMyProfile(firstName: nil, displayName: trimmed)
                await MainActor.run {
                    savingName = false
                    nameSavedMessage = "Saved."
                }
            } catch {
                await MainActor.run {
                    savingName = false
                    nameSavedMessage = "Couldn't save: \(error.localizedDescription)"
                }
            }
        }
    }

    private func performDelete() {
        isDeleting = true
        deleteError = nil
        SupabaseSync.shared.deleteAllUserData { ok in
            isDeleting = false
            if ok {
                auth.signOut()
                dismiss()
            } else {
                deleteError = "Some data could not be deleted. Try again or contact support."
            }
        }
    }
}
