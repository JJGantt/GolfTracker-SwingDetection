import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: DataStore
    @ObservedObject private var auth = AuthManager.shared
    @ObservedObject private var connectivity = WatchConnectivityManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showingClubManagement = false
    @State private var showingSignOutConfirm = false
    @State private var showingDeleteConfirm = false
    @State private var isDeleting = false
    @State private var deleteError: String?
    @AppStorage(PlaygroupChannel.liveDotsEnabledKey) private var liveDotsEnabled = true
    @AppStorage(ClientEventLogger.userDefaultsKey) private var debugLoggingEnabled = false
    @AppStorage("swingTestModeEnabled") private var swingTestModeEnabled = false
    @AppStorage("autoAdvanceGreenLeftThresholdYards") private var greenLeftThresholdYards: Double = 10
    @AppStorage("autoAdvanceTeeBoxThresholdYards") private var teeBoxThresholdYards: Double = 10
    @AppStorage("autoAdvanceHistoricalShotThresholdYards") private var historicalShotThresholdYards: Double = 10
    @AppStorage("greenPutterMarginYards") private var greenPutterMarginYards: Double = 2
    @AppStorage("ignorePracticeRadius") private var ignorePracticeRadius: Double = 20
    @AppStorage("practiceStepGateThreshold") private var practiceStepGateThreshold: Int = 10
    @AppStorage("detectionMode") private var detectionMode: String = "Unif"
    @AppStorage("autoAdd") private var autoAdd: Bool = true
    @AppStorage(ElevationReadout.decayTauKey) private var elevationTauMinutes: Double = ElevationReadout.defaultDecayTauMinutes
    @AppStorage(LocationManager.forceFullGPSKey) private var elevationForceFullGPS: Bool = false
    @AppStorage("runHoleDetectionAtRoundStart") private var runHoleDetectionAtRoundStart = true
    @AppStorage("runHoleDetectionWithTestCenter") private var runHoleDetectionWithTestCenter = false

    @State private var currentName: String = ""
    /// Hidden developer section, revealed by long-pressing the Settings
    /// title. Persists across this view's lifetime but resets on dismiss
    /// so casual users don't stumble into it.
    @State private var showingDeveloper = false

    /// Tints the watch-build row when the two devices are on different builds,
    /// which is the whole reason the rows exist. Treated as matching until the
    /// watch has reported anything, so an un-launched watch app doesn't read as
    /// a mismatch.
    private var buildsMatch: Bool {
        guard let w = connectivity.watchBuild else { return true }
        return w == WatchConnectivityManager.localBuild
    }

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

                Section("Clubs") {
                    Button {
                        showingClubManagement = true
                    } label: {
                        Label("Manage Clubs & Sets", systemImage: "figure.golf")
                            .foregroundColor(.primary)
                    }
                }

                Section("Multiplayer") {
                    // This used to be an inert grey label, so multiplayer was
                    // reachable only from the watch — the iPhone had no path
                    // to host or join at all.
                    NavigationLink {
                        MultiplayerView()
                    } label: {
                        Label("Play with friends", systemImage: "person.2.fill")
                    }
                    Toggle("Share my position", isOn: $liveDotsEnabled)
                }

                if showingDeveloper {
                    Section("Developer") {
                        // Which build is on each device. The watch app installs
                        // asynchronously after the phone's copy and can lag well
                        // behind, and neither app shows what it is running — so a
                        // stale watch binary is indistinguishable from a bug in
                        // the current one. `watchBuild` is nil until the watch
                        // has activated a session at least once since install.
                        LabeledContent("Build", value: WatchConnectivityManager.localBuild)
                        LabeledContent("Watch build",
                                       value: connectivity.watchBuild ?? "—")
                            .foregroundStyle(buildsMatch ? Color.primary : Color.orange)

                        NavigationLink {
                            TestModeView()
                        } label: {
                            Label("Test Mode (GPS sim)", systemImage: "scope")
                        }
                        Button {
                            store.rebuildPlayerStats()
                        } label: {
                            Label("Rebuild Stats", systemImage: "arrow.clockwise")
                        }
                        Button {
                            store.seedDemoData()
                        } label: {
                            Label("Seed Demo Data", systemImage: "wand.and.stars")
                        }
                        Button(role: .destructive) {
                            store.clearDemoData()
                        } label: {
                            Label("Clear Demo Data", systemImage: "trash")
                        }
                        Toggle("Debug logging", isOn: $debugLoggingEnabled)
                            .onChange(of: debugLoggingEnabled) { _, newValue in
                                WatchConnectivityManager.shared.sendDebugLoggingEnabled(newValue)
                            }

                        // Exposes the Swing Test button on the watch home
                        // screen — the detector running with no round, for
                        // labeling false positives and misses deliberately.
                        Toggle("Swing test mode (watch)", isOn: $swingTestModeEnabled)
                            .onChange(of: swingTestModeEnabled) { _, newValue in
                                WatchConnectivityManager.shared.sendDevParam(
                                    key: "swingTestModeEnabled", boolValue: newValue)
                            }

                        // Moved here from CourseDetailView, which is now a
                        // user-facing screen reached by tapping a course in
                        // Stats. These control the satellite-blob green
                        // analyzer and are dev controls, not course settings.
                        Toggle("Run hole detection at round start", isOn: $runHoleDetectionAtRoundStart)
                        Toggle("Hole detection: test coordinates", isOn: $runHoleDetectionWithTestCenter)
                            .disabled(!runHoleDetectionAtRoundStart)

                        Stepper(value: $greenLeftThresholdYards, in: 5...60, step: 5) {
                            Text("Auto-advance: \(Int(greenLeftThresholdYards)) yd from green edge")
                                .font(.caption)
                        }
                        .onChange(of: greenLeftThresholdYards) { _, newValue in
                            WatchConnectivityManager.shared.sendDevParam(key: "autoAdvanceGreenLeftThresholdYards", doubleValue: newValue)
                        }

                        Stepper(value: $teeBoxThresholdYards, in: 3...30, step: 1) {
                            Text("Auto-advance: \(Int(teeBoxThresholdYards)) yd from next centerline (OSM)")
                                .font(.caption)
                        }
                        .onChange(of: teeBoxThresholdYards) { _, newValue in
                            WatchConnectivityManager.shared.sendDevParam(key: "autoAdvanceTeeBoxThresholdYards", doubleValue: newValue)
                        }

                        Stepper(value: $historicalShotThresholdYards, in: 3...30, step: 1) {
                            Text("Auto-advance: \(Int(historicalShotThresholdYards)) yd from prior first-stroke")
                                .font(.caption)
                        }
                        .onChange(of: historicalShotThresholdYards) { _, newValue in
                            WatchConnectivityManager.shared.sendDevParam(key: "autoAdvanceHistoricalShotThresholdYards", doubleValue: newValue)
                        }

                        Stepper(value: $greenPutterMarginYards, in: 0...20, step: 1) {
                            Text("Putter switch margin: \(Int(greenPutterMarginYards)) yd")
                                .font(.caption)
                        }
                        .onChange(of: greenPutterMarginYards) { _, newValue in
                            WatchConnectivityManager.shared.sendDevParam(key: "greenPutterMarginYards", doubleValue: newValue)
                        }

                        Toggle("unif_detect", isOn: Binding(
                            get: { detectionMode == "Unif" },
                            set: { newValue in
                                detectionMode = newValue ? "Unif" : "Off"
                                WatchConnectivityManager.shared.sendDevParam(key: "detectionMode", stringValue: detectionMode)
                            }
                        ))

                        
                        Toggle("Auto Add", isOn: $autoAdd)
                            .onChange(of: autoAdd) { _, newValue in
                                WatchConnectivityManager.shared.sendDevParam(key: "autoAdd", boolValue: newValue)
                            }

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

                        NavigationLink {
                            GreenFiltersView()
                        } label: {
                            Text("Blob filters")
                        }

                        Stepper(value: $elevationTauMinutes, in: 5...60, step: 5) {
                            Text("Elev calib τ: \(Int(elevationTauMinutes)) min")
                                .font(.caption)
                        }
                        .onChange(of: elevationTauMinutes) { _, newValue in
                            WatchConnectivityManager.shared.sendDevParam(
                                key: ElevationReadout.decayTauKey, doubleValue: newValue
                            )
                        }

                        Toggle("Force full-fidelity GPS during round", isOn: $elevationForceFullGPS)
                            .onChange(of: elevationForceFullGPS) { _, newValue in
                                WatchConnectivityManager.shared.sendDevParam(
                                    key: LocationManager.forceFullGPSKey, boolValue: newValue
                                )
                            }
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
            .sheet(isPresented: $showingClubManagement) {
                ClubManagementView()
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
