import Foundation
import CoreLocation
import Supabase

/// Multiplayer rounds — host/join/accept/decline/end. Shared between iOS and
/// watchOS; both platforms have the same Multiplayer view in Settings, the
/// same join-request flow, and the same color-per-player palette.
///
/// State lives in Supabase (`playgroups`, `playgroup_members`,
/// `playgroup_join_requests`); this service is the read/write wrapper.
/// Realtime subscriptions for the playgroup-channel are layered on top by
/// `RealtimeSync` (round-scoped lifecycle, started when active round screen
/// is visible).
final class PlaygroupService {
    static let shared = PlaygroupService()

    private let supabase = SupabaseManager.shared
    private init() {}

    // MARK: - Color palette

    /// 6 hex colors for player assignment, in order. The Nth member of a
    /// playgroup gets palette[N]. Same color is used in their map markers
    /// and their scorecard column header throughout the round.
    static let playerPalette: [String] = [
        "#3B82F6",  // blue (host)
        "#EF4444",  // red
        "#10B981",  // green
        "#F59E0B",  // amber
        "#8B5CF6",  // violet
        "#14B8A6",  // teal
    ]

    // MARK: - Hosting

    /// Create a new playgroup with the current user as host. The user's own
    /// round (which they'd already started via the regular flow) becomes the
    /// host's round in this playgroup. Returns the new playgroup row.
    func hostPlaygroup(courseId: UUID?, courseName: String, roundId: UUID, name: String? = nil, hostLocation: CLLocationCoordinate2D? = nil) async throws -> Playgroup {
        guard let userId = currentUserId() else { throw PlaygroupError.notSignedIn }

        struct InsertRow: Encodable {
            let host_id: String
            let course_id: String?
            let course_name: String
            let name: String?
            let host_lat: Double?
            let host_lon: Double?
        }
        let row = InsertRow(
            host_id: userId,
            course_id: courseId?.uuidString,
            course_name: courseName,
            name: name,
            host_lat: hostLocation?.latitude,
            host_lon: hostLocation?.longitude
        )
        let inserted: Playgroup = try await supabase.from("playgroups")
            .insert(row, returning: .representation)
            .select()
            .single()
            .execute()
            .value

        // Insert host as the first member with their round_id + first palette color.
        struct MemberRow: Encodable {
            let playgroup_id: String
            let user_id: String
            let round_id: String?
            let color: String?
        }
        let memberRow = MemberRow(
            playgroup_id: inserted.id.uuidString,
            user_id: userId,
            round_id: roundId.uuidString,
            color: PlaygroupService.playerPalette.first
        )
        try await supabase.from("playgroup_members").insert(memberRow).execute()

        return inserted
    }

    // MARK: - Discovery (Join screen)

    /// Maximum distance (meters) between joiner's current GPS and the host's
    /// recorded GPS for a playgroup to appear in the joiner's "Nearby" list.
    /// Tight on purpose — multiplayer is for people physically together at
    /// the same course, not "anyone on the same continent."
    static let nearbyMaxMeters: Double = 100

    /// Returns playgroups the user can join: open status, NOT a group they're
    /// already in, AND (when `currentLocation` is provided) within
    /// `nearbyMaxMeters` of the host's recorded GPS. If the joiner has no GPS
    /// yet, returns an empty list rather than the global open set — pairing
    /// across the country is never the right answer.
    func nearbyJoinable(currentLocation: CLLocationCoordinate2D?) async throws -> [Playgroup] {
        guard let userId = currentUserId() else { throw PlaygroupError.notSignedIn }
        guard let here = currentLocation else { return [] }
        let groups: [Playgroup] = try await supabase.from("playgroups")
            .select()
            .eq("status", value: "open")
            .order("started_at", ascending: false)
            .execute()
            .value
        // Filter out groups the user is already in.
        let myMemberships: [PlaygroupMember] = try await supabase.from("playgroup_members")
            .select()
            .eq("user_id", value: userId)
            .execute()
            .value
        let myGroupIds = Set(myMemberships.map { $0.playgroupId })
        let hereLoc = CLLocation(latitude: here.latitude, longitude: here.longitude)
        return groups.filter { pg in
            guard !myGroupIds.contains(pg.id) else { return false }
            guard let lat = pg.hostLat, let lon = pg.hostLon else { return false }
            let hostLoc = CLLocation(latitude: lat, longitude: lon)
            return hereLoc.distance(from: hostLoc) <= PlaygroupService.nearbyMaxMeters
        }
    }

    // MARK: - Join flow

    /// Send a join request to the host of the given playgroup. Host sees it
    /// in their Pending Requests list and accepts/declines.
    func requestJoin(playgroupId: UUID) async throws {
        guard let userId = currentUserId() else { throw PlaygroupError.notSignedIn }
        struct Row: Encodable {
            let playgroup_id: String
            let requester_id: String
        }
        let row = Row(playgroup_id: playgroupId.uuidString, requester_id: userId)
        try await supabase.from("playgroup_join_requests")
            .upsert(row, onConflict: "playgroup_id,requester_id")
            .execute()
    }

    /// Read pending requests for playgroups I'm hosting. Used by the host's
    /// Multiplayer view to show the Accept/Decline list.
    func pendingRequests(forHostedPlaygroup playgroupId: UUID) async throws -> [PlaygroupJoinRequest] {
        try await supabase.from("playgroup_join_requests")
            .select()
            .eq("playgroup_id", value: playgroupId)
            .eq("status", value: "pending")
            .order("requested_at")
            .execute()
            .value
    }

    /// Accept a join request — adds the requester as a playgroup member with
    /// the next available palette color. Their round_id is attached separately
    /// once they actually start a round in the shared session.
    func acceptRequest(_ request: PlaygroupJoinRequest, theirRoundId: UUID? = nil) async throws {
        // Pick next available palette color
        let existingMembers: [PlaygroupMember] = try await supabase.from("playgroup_members")
            .select()
            .eq("playgroup_id", value: request.playgroupId)
            .execute()
            .value
        let usedColors = Set(existingMembers.compactMap { $0.color })
        let nextColor = PlaygroupService.playerPalette.first { !usedColors.contains($0) }

        struct MemberRow: Encodable {
            let playgroup_id: String
            let user_id: String
            let round_id: String?
            let color: String?
        }
        let memberRow = MemberRow(
            playgroup_id: request.playgroupId.uuidString,
            user_id: request.requesterId,
            round_id: theirRoundId?.uuidString,
            color: nextColor
        )
        try await supabase.from("playgroup_members").insert(memberRow).execute()

        // Mark the request as accepted.
        struct Update: Encodable {
            let status: String
            let responded_at: String
        }
        let update = Update(status: "accepted", responded_at: ISO8601DateFormatter().string(from: Date()))
        try await supabase.from("playgroup_join_requests")
            .update(update)
            .eq("id", value: request.id)
            .execute()
    }

    /// Point my membership row at the round I'm actually playing.
    ///
    /// The host gets a `round_id` at `hostPlaygroup` time, but a joiner's row
    /// is inserted by `acceptRequest` with `round_id = nil` — the host has no
    /// way to know the joiner's round, and join requests don't carry one. Until
    /// this write happens the joiner is invisible to everything keyed on their
    /// round: `fetchScorecardPlayers` filters them out (leaving one player,
    /// below the `>= 2` threshold, so the shared scorecard silently renders as
    /// a solo card) and no stroke subscription is wired for them.
    ///
    /// Called on every playgroup-channel start, so it also re-points the row
    /// when someone ends a round and begins another inside the same playgroup.
    /// RLS (`pm_update_self_or_host`) already allows updating your own row, so
    /// this needs no schema or policy change. Co-members pick the change up
    /// through the existing `playgroup_members` postgres-changes subscription.
    func attachMyRound(playgroupId: UUID, roundId: UUID) async {
        guard let uid = SupabaseManager.shared.auth.currentUser?.id.uuidString else { return }
        struct Update: Encodable { let round_id: String }
        do {
            try await supabase.from("playgroup_members")
                .update(Update(round_id: roundId.uuidString))
                .eq("playgroup_id", value: playgroupId.uuidString)
                .eq("user_id", value: uid)
                .execute()
        } catch {
            dprint("📡 [PlaygroupService] attachMyRound failed: \(error.localizedDescription)")
        }
    }

    func declineRequest(_ request: PlaygroupJoinRequest) async throws {
        struct Update: Encodable {
            let status: String
            let responded_at: String
        }
        let update = Update(status: "declined", responded_at: ISO8601DateFormatter().string(from: Date()))
        try await supabase.from("playgroup_join_requests")
            .update(update)
            .eq("id", value: request.id)
            .execute()
    }

    // MARK: - Read state

    /// All members of a playgroup, sorted by join time.
    func members(of playgroupId: UUID) async throws -> [PlaygroupMember] {
        try await supabase.from("playgroup_members")
            .select()
            .eq("playgroup_id", value: playgroupId)
            .order("joined_at")
            .execute()
            .value
    }

    /// The single playgroup the current user is currently a member of, if any
    /// (in 'open' status). Most users are in at most one open playgroup at a
    /// time; if more than one, returns the most-recent.
    func currentOpenPlaygroup() async throws -> Playgroup? {
        guard let userId = currentUserId() else { return nil }
        let myMemberships: [PlaygroupMember] = try await supabase.from("playgroup_members")
            .select()
            .eq("user_id", value: userId)
            .execute()
            .value
        let groupIds = myMemberships.map { $0.playgroupId.uuidString }
        guard !groupIds.isEmpty else { return nil }
        let groups: [Playgroup] = try await supabase.from("playgroups")
            .select()
            .in("id", values: groupIds)
            .eq("status", value: "open")
            .order("started_at", ascending: false)
            .limit(1)
            .execute()
            .value
        return groups.first
    }

    /// Look up display names for a set of user ids (for showing player names
    /// in the join picker, member list, scorecard headers).
    func profiles(for userIds: [String]) async throws -> [String: UserProfile] {
        guard !userIds.isEmpty else { return [:] }
        let rows: [UserProfile] = try await supabase.from("profiles")
            .select()
            .in("user_id", values: userIds)
            .execute()
            .value
        var byId: [String: UserProfile] = [:]
        for p in rows { byId[p.userId] = p }
        return byId
    }

    // MARK: - End / leave

    /// Host ends the playgroup — closes to new joiners + sets ended_at. Round
    /// data persists; this just transitions joinability.
    func endPlaygroup(_ playgroupId: UUID) async throws {
        struct Update: Encodable {
            let status: String
            let closed_at: String
            let ended_at: String
        }
        let now = ISO8601DateFormatter().string(from: Date())
        let update = Update(status: "closed", closed_at: now, ended_at: now)
        try await supabase.from("playgroups")
            .update(update)
            .eq("id", value: playgroupId)
            .execute()
    }

    /// Self-leave a playgroup. Host can also remove a member via the same call.
    func leavePlaygroup(_ playgroupId: UUID, userId: String? = nil) async throws {
        let target = userId ?? currentUserId() ?? ""
        guard !target.isEmpty else { throw PlaygroupError.notSignedIn }
        try await supabase.from("playgroup_members")
            .delete()
            .eq("playgroup_id", value: playgroupId)
            .eq("user_id", value: target)
            .execute()
    }

    // MARK: - Profile

    /// Upsert the current user's display name. Called from:
    /// 1. SIWA flow on first sign-in (Apple gives us first/last name *only*
    ///    on the very first sign-in for the app — never again, deliberately
    ///    by Apple's privacy design). We capture it then or we lose it.
    /// 2. The Settings name editor — user-editable override anytime.
    /// 3. The Multiplayer first-time prompt — fallback for legacy users
    ///    who already signed in before profiles existed.
    func upsertMyProfile(firstName: String?, displayName: String?) async throws {
        guard let userId = currentUserId() else { throw PlaygroupError.notSignedIn }
        struct Row: Encodable {
            let user_id: String
            let first_name: String?
            let display_name: String?
            let updated_at: String
        }
        let row = Row(
            user_id: userId,
            first_name: firstName,
            display_name: displayName,
            updated_at: ISO8601DateFormatter().string(from: Date())
        )
        try await supabase.from("profiles")
            .upsert(row, onConflict: "user_id")
            .execute()
    }

    /// Fetch the current user's own profile row, if it exists. Returns nil
    /// when the user hasn't set a name yet — UI uses that to decide whether
    /// to show the first-time-name prompt.
    func myProfile() async throws -> UserProfile? {
        guard let userId = currentUserId() else { return nil }
        let rows: [UserProfile] = try await supabase.from("profiles")
            .select()
            .eq("user_id", value: userId)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    // MARK: - Helpers

    private func currentUserId() -> String? {
        #if os(watchOS)
        return WatchAuthSession.shared.currentUserId
        #else
        return AuthManager.shared.currentUserId
        #endif
    }
}

enum PlaygroupError: Error, LocalizedError {
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in"
        }
    }
}
