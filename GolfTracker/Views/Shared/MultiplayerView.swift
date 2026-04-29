import SwiftUI

/// Multiplayer entry-point view. Three sections:
///   1. Current playgroup (if any) — shows members + Leave button (or End for host)
///   2. Pending join requests (host-only)
///   3. Host Round / Join Round buttons + nearby joinable groups
///
/// Same layout on iOS and watchOS — the watch screen is narrow but the
/// content is mostly text, fits fine. Compiled into both targets.
struct MultiplayerView: View {
    @State private var currentPlaygroup: Playgroup?
    @State private var members: [PlaygroupMember] = []
    @State private var profiles: [String: UserProfile] = [:]
    @State private var pendingRequests: [PlaygroupJoinRequest] = []
    @State private var nearbyJoinable: [Playgroup] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showHostConfirm = false

    private var currentUserId: String? {
        #if os(watchOS)
        WatchAuthSession.shared.currentUserId
        #else
        AuthManager.shared.currentUserId
        #endif
    }

    private var iAmHost: Bool {
        guard let pg = currentPlaygroup, let uid = currentUserId else { return false }
        return pg.hostId == uid
    }

    var body: some View {
        List {
            if let pg = currentPlaygroup {
                currentPlaygroupSection(pg)
            }

            if iAmHost && !pendingRequests.isEmpty {
                Section("Pending requests") {
                    ForEach(pendingRequests) { req in
                        pendingRow(req)
                    }
                }
            }

            if currentPlaygroup == nil {
                Section {
                    Button {
                        showHostConfirm = true
                    } label: {
                        Label("Host Round", systemImage: "flag.fill")
                    }
                    .disabled(currentRoundId == nil)

                    if currentRoundId == nil {
                        Text("Start a round first, then host it here.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section("Nearby") {
                if nearbyJoinable.isEmpty {
                    Text(isLoading ? "Loading…" : "No open rounds nearby")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(nearbyJoinable) { pg in
                        nearbyRow(pg)
                    }
                }
            }

            if let err = errorMessage {
                Section { Text(err).font(.caption).foregroundColor(.red) }
            }
        }
        .navigationTitle("Multiplayer")
        .task { await reload() }
        .refreshable { await reload() }
        .alert("Host this round?", isPresented: $showHostConfirm) {
            Button("Host") { Task { await host() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Other players nearby will be able to request to join.")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func currentPlaygroupSection(_ pg: Playgroup) -> some View {
        Section(pg.courseName) {
            ForEach(members, id: \.userId) { member in
                memberRow(member)
            }
            if iAmHost {
                Button(role: .destructive) {
                    Task { await endPlaygroup(pg) }
                } label: {
                    Label("End round", systemImage: "stop.circle")
                }
            } else {
                Button(role: .destructive) {
                    Task { await leave(pg) }
                } label: {
                    Label("Leave round", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
    }

    @ViewBuilder
    private func memberRow(_ member: PlaygroupMember) -> some View {
        HStack {
            Circle()
                .fill(Color(hex: member.color ?? "#999999"))
                .frame(width: 12, height: 12)
            Text(profiles[member.userId]?.resolvedName ?? "Player")
            if let pg = currentPlaygroup, pg.hostId == member.userId {
                Text("host")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func pendingRow(_ req: PlaygroupJoinRequest) -> some View {
        HStack {
            Text(profiles[req.requesterId]?.resolvedName ?? "Player")
                .font(.body)
            Spacer()
            Button("Accept") { Task { await accept(req) } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("Decline", role: .destructive) { Task { await decline(req) } }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func nearbyRow(_ pg: Playgroup) -> some View {
        Button {
            Task { await requestJoin(pg) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(profiles[pg.hostId]?.resolvedName ?? "Player").fontWeight(.semibold)
                    Text("at").foregroundColor(.secondary)
                    Text(pg.courseName).foregroundColor(.secondary)
                }
                Text("Tap to request")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Data

    private var currentRoundId: UUID? {
        #if os(watchOS)
        return WatchDataStore.shared.currentRoundId
        #else
        return nil  // iOS round id resolution comes via active HolePlayView; not exposed here yet
        #endif
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let pg = try await PlaygroupService.shared.currentOpenPlaygroup()
            self.currentPlaygroup = pg

            if let pg = pg {
                let m = try await PlaygroupService.shared.members(of: pg.id)
                self.members = m
                if iAmHost {
                    self.pendingRequests = try await PlaygroupService.shared.pendingRequests(forHostedPlaygroup: pg.id)
                } else {
                    self.pendingRequests = []
                }
            } else {
                self.members = []
                self.pendingRequests = []
            }

            self.nearbyJoinable = try await PlaygroupService.shared.nearbyJoinable(currentLocation: nil)

            // Pull profiles for everyone we'll display.
            var ids = Set<String>()
            members.forEach { ids.insert($0.userId) }
            pendingRequests.forEach { ids.insert($0.requesterId) }
            nearbyJoinable.forEach { ids.insert($0.hostId) }
            self.profiles = try await PlaygroupService.shared.profiles(for: Array(ids))

            self.errorMessage = nil
        } catch {
            self.errorMessage = "Couldn't load: \(error.localizedDescription)"
        }
    }

    private func host() async {
        guard let roundId = currentRoundId else { return }
        // Need a course for the playgroup — pull it from the current round.
        #if os(watchOS)
        guard let round = WatchDataStore.shared.currentRound else { return }
        do {
            _ = try await PlaygroupService.shared.hostPlaygroup(
                courseId: round.courseId,
                courseName: round.courseName,
                roundId: roundId
            )
            await reload()
        } catch {
            self.errorMessage = "Host failed: \(error.localizedDescription)"
        }
        #endif
    }

    private func requestJoin(_ pg: Playgroup) async {
        do {
            try await PlaygroupService.shared.requestJoin(playgroupId: pg.id)
            await reload()
        } catch {
            self.errorMessage = "Join request failed: \(error.localizedDescription)"
        }
    }

    private func accept(_ req: PlaygroupJoinRequest) async {
        do {
            try await PlaygroupService.shared.acceptRequest(req)
            await reload()
        } catch {
            self.errorMessage = "Accept failed: \(error.localizedDescription)"
        }
    }

    private func decline(_ req: PlaygroupJoinRequest) async {
        do {
            try await PlaygroupService.shared.declineRequest(req)
            await reload()
        } catch {
            self.errorMessage = "Decline failed: \(error.localizedDescription)"
        }
    }

    private func endPlaygroup(_ pg: Playgroup) async {
        do {
            try await PlaygroupService.shared.endPlaygroup(pg.id)
            await reload()
        } catch {
            self.errorMessage = "End failed: \(error.localizedDescription)"
        }
    }

    private func leave(_ pg: Playgroup) async {
        do {
            try await PlaygroupService.shared.leavePlaygroup(pg.id)
            await reload()
        } catch {
            self.errorMessage = "Leave failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Color hex helper

extension Color {
    /// Decode a "#RRGGBB" or "RRGGBB" hex string. Falls back to gray on bad input.
    init(hex: String) {
        var hex = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let val = UInt64(hex, radix: 16) else {
            self = .gray
            return
        }
        let r = Double((val >> 16) & 0xFF) / 255
        let g = Double((val >>  8) & 0xFF) / 255
        let b = Double( val        & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}
