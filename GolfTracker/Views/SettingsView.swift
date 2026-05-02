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
    @AppStorage(ClientEventLogger.userDefaultsKey) private var debugLoggingEnabled = false
    @AppStorage("autoAdvanceGreenLeftThresholdYards") private var greenLeftThresholdYards: Double = 10
    @AppStorage("greenPutterMarginYards") private var greenPutterMarginYards: Double = 2
    @AppStorage("ignorePracticeRadius") private var ignorePracticeRadius: Double = 20
    @AppStorage("practiceStepGateThreshold") private var practiceStepGateThreshold: Int = 10

    @State private var currentName: String = ""
    /// Hidden developer section, revealed by long-pressing the Settings
    /// title. Persists across this view's lifetime but resets on dismiss
    /// so casual users don't stumble into it.
    @State private var showingDeveloper = false

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

                    NavigationLink {
                        NameEditView(initial: currentName) { newName in
                            try await PlaygroupService.shared.upsertMyProfile(firstName: nil, displayName: newName)
                            await MainActor.run { currentName = newName }
                        }
                    } label: {
                        LabeledContent("Display name") {
                            Text(currentName.isEmpty ? "Not set" : currentName)
                                .foregroundColor(currentName.isEmpty ? .secondary : .primary)
                        }
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

                if showingDeveloper {
                    Section("Developer") {
                        NavigationLink {
                            TestModeView()
                        } label: {
                            Label("Test Mode (GPS sim)", systemImage: "scope")
                        }
                        Toggle("Debug logging", isOn: $debugLoggingEnabled)
                            .onChange(of: debugLoggingEnabled) { _, newValue in
                                // Mirror to the watch — both devices' loggers
                                // read the same UserDefaults key, but watch's
                                // UserDefaults is local, so we ship the value
                                // over WC.
                                WatchConnectivityManager.shared.sendDebugLoggingEnabled(newValue)
                            }
                        Text("Forwards `client_events` rows for diagnostics. Off by default; only turn on while actively investigating an issue.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Stepper(value: $greenLeftThresholdYards, in: 5...60, step: 5) {
                            Text("Auto-advance: \(Int(greenLeftThresholdYards)) yd from green edge")
                                .font(.caption)
                        }
                        .onChange(of: greenLeftThresholdYards) { _, newValue in
                            WatchConnectivityManager.shared.sendDevParam(key: "autoAdvanceGreenLeftThresholdYards", doubleValue: newValue)
                        }

                        Stepper(value: $greenPutterMarginYards, in: 0...20, step: 1) {
                            Text("Putter switch margin: \(Int(greenPutterMarginYards)) yd")
                                .font(.caption)
                        }
                        .onChange(of: greenPutterMarginYards) { _, newValue in
                            WatchConnectivityManager.shared.sendDevParam(key: "greenPutterMarginYards", doubleValue: newValue)
                        }
                        Text("When green polygon is available, switching to putter fires inside the polygon OR within this margin of its edge. Yardage-based switch is bypassed in that case. Set 0 to require strict polygon containment.")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Stepper(value: $ignorePracticeRadius, in: 5...60, step: 5) {
                            Text("Practice radius: \(Int(ignorePracticeRadius)) yd")
                                .font(.caption)
                        }
                        .onChange(of: ignorePracticeRadius) { _, newValue in
                            WatchConnectivityManager.shared.sendDevParam(key: "ignorePracticeRadius", doubleValue: newValue)
                        }

                        Stepper(value: $practiceStepGateThreshold, in: 1...500) {
                            Text("Practice step gate: \(practiceStepGateThreshold) steps")
                                .font(.caption)
                        }
                        .onChange(of: practiceStepGateThreshold) { _, newValue in
                            WatchConnectivityManager.shared.sendDevParam(key: "practiceStepGateThreshold", intValue: newValue)
                        }
                        Text("Practice radius + step gate together decide whether a new swing replaces the previous (practice swing) instead of adding a new stroke. Step threshold = arbitrarily high to disable.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Section {
                    EmptyView()
                } footer: {
                    Link(destination: URL(string: "https://www.openstreetmap.org/copyright")!) {
                        Text("Map data © OpenStreetMap contributors")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    // Long-press the title to reveal the Developer section
                    // (Test Mode etc). Tap is a no-op for normal users.
                    Text("Settings")
                        .font(.headline)
                        .onLongPressGesture(minimumDuration: 1.0) {
                            withAnimation { showingDeveloper.toggle() }
                        }
                }
            }
            .task {
                if let p = try? await PlaygroupService.shared.myProfile() {
                    let pre = p.displayName ?? p.firstName ?? ""
                    if currentName.isEmpty { currentName = pre }
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

// MARK: - NameEditView

/// Single-field name editor. Used in two places:
/// 1. Pushed from Settings → Display name (with Cancel — user can back out).
/// 2. Presented as a first-launch gate for accounts whose profile has no
///    name yet (no Cancel — must save before proceeding).
struct NameEditView: View {
    let title: String
    let initial: String
    let prompt: String?
    let allowCancel: Bool
    let onSave: (String) async throws -> Void

    @State private var name: String
    @State private var saving = false
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(title: String = "Display name",
         initial: String,
         prompt: String? = nil,
         allowCancel: Bool = true,
         onSave: @escaping (String) async throws -> Void) {
        self.title = title
        self.initial = initial
        self.prompt = prompt
        self.allowCancel = allowCancel
        self.onSave = onSave
        _name = State(initialValue: initial)
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        guard !saving, !trimmed.isEmpty else { return false }
        // Allow saving the prefilled value when this is a first-time prompt
        // (initial is blank → any non-empty entry is a real save). Otherwise
        // require a change vs. what's already stored.
        if initial.isEmpty { return true }
        return trimmed != initial.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if allowCancel {
                content
            } else {
                NavigationStack { content }
            }
        }
    }

    private var content: some View {
        Form {
            Section {
                TextField("First name", text: $name)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .focused($fieldFocused)
                    .submitLabel(.done)
                    .onSubmit { if canSave { save() } }
            } header: {
                if let prompt = prompt {
                    Text(prompt).textCase(nil)
                } else {
                    Text("This is how playgroup partners see you.").textCase(nil)
                }
            }

            if let err = errorMessage {
                Text(err).font(.caption).foregroundColor(.red)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { fieldFocused = false }
            }
        }
        .onAppear { fieldFocused = true }
        .interactiveDismissDisabled(!allowCancel)
    }

    private func save() {
        let value = trimmed
        guard !value.isEmpty else { return }
        saving = true
        errorMessage = nil
        Task {
            do {
                try await onSave(value)
                await MainActor.run {
                    saving = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    saving = false
                    errorMessage = "Couldn't save: \(error.localizedDescription)"
                }
            }
        }
    }
}
