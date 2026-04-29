import SwiftUI

/// Loads the cached tee + per-hole data for the round's selected tee, then
/// presents `ScorecardView`. Wraps the async fetch so the view layer doesn't
/// need to know about the GolfCourseAPI cache.
///
/// Used on both iOS (round-summary sheet) and watchOS (button on active round).
struct ScorecardSheet: View {
    let round: Round

    @State private var teeHoles: [Int: CachedCourseTeeHole]? = nil
    @State private var teeName: String? = nil
    @State private var loaded = false
    @State private var players: [PlaygroupChannel.ScorecardPlayer] = []

    @ObservedObject private var playgroup = PlaygroupChannel.shared

    var body: some View {
        ScorecardView(round: round, teeHoles: teeHoles, teeName: teeName, players: players)
            .task(id: round.selectedTeeId) {
                await loadSoloTee()
            }
            .task(id: playgroup.activePlaygroupId) {
                await loadPlaygroupPlayers()
            }
    }

    /// Solo tee data — used both for the solo layout and as the "self
    /// reference" tee column when the playgroup variant kicks in.
    private func loadSoloTee() async {
        guard !loaded else { return }
        guard let teeId = round.selectedTeeId else {
            loaded = true
            return
        }
        do {
            let holes = try await GolfCourseAPIService.shared.cachedHoles(forTeeId: teeId)
            let tees: [CachedCourseTee] = try await SupabaseManager.shared.from("course_tees")
                .select()
                .eq("id", value: teeId)
                .limit(1)
                .execute()
                .value
            let name = tees.first?.teeName
            var byHole: [Int: CachedCourseTeeHole] = [:]
            for h in holes { byHole[h.holeNumber] = h }
            await MainActor.run {
                self.teeHoles = byHole
                self.teeName = name
                self.loaded = true
            }
        } catch {
            dprint("[ScorecardSheet] tee data load failed: \(error.localizedDescription)")
            await MainActor.run { self.loaded = true }
        }
    }

    /// Multiplayer payload. Empty when not in a playgroup, which keeps the
    /// solo single-column layout unchanged.
    private func loadPlaygroupPlayers() async {
        guard playgroup.activePlaygroupId != nil else {
            await MainActor.run { self.players = [] }
            return
        }
        let myUid: String? = {
            #if os(watchOS)
            return WatchAuthSession.shared.currentUserId
            #else
            return AuthManager.shared.currentUserId
            #endif
        }()
        guard let _ = myUid else { return }

        // Pull display-name profiles for every member so the column headers
        // aren't all "Player". Same lookup MultiplayerView uses.
        let memberIds = playgroup.members.map { $0.userId }
        let profileMap = (try? await PlaygroupService.shared.profiles(for: memberIds)) ?? [:]
        let myDisplay = profileMap[myUid ?? ""]?.resolvedName ?? "Me"

        let result = await playgroup.fetchScorecardPlayers(
            selfRound: round,
            selfDisplayName: myDisplay,
            profileLookup: profileMap
        )
        await MainActor.run { self.players = result }
    }
}
