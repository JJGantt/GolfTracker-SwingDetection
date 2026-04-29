import Foundation
import Combine
import CoreLocation
import Supabase

/// Owns the `playgroup:<id>` Realtime channel for the user's current
/// open playgroup. Three responsibilities:
///
///   1. **Presence (live dots)** — every `presenceTickSeconds` while
///      `liveDotsEnabled`, calls `channel.track(state:)` with the user's
///      current GPS. Listens to presence changes and republishes them
///      as `presence: [userId: MemberPresence]`.
///   2. **Other-player strokes** — fetches members of the playgroup, then
///      pulls each non-self member's strokes for the current hole. Subscribes
///      to postgres-changes on `strokes` filtered to those round_ids so
///      updates flow in live. Lives in-memory (NOT SwiftData), since these
///      rounds are not owned by the local user.
///   3. **Members snapshot** — `members: [PlaygroupMember]` for color lookup.
///
/// **Lifecycle**: started from the active-round view (HolePlayView on iOS,
/// ActiveRoundView on watchOS) `.onAppear` when `currentOpenPlaygroup()` is
/// non-nil, stopped on `.onDisappear`. Mirrors `RealtimeSync`'s
/// round-scoped lifecycle so we don't burn a WebSocket while idle.
@MainActor
final class PlaygroupChannel: ObservableObject {
    static let shared = PlaygroupChannel()

    @Published private(set) var members: [PlaygroupMember] = []
    @Published private(set) var presence: [String: MemberPresence] = [:]
    @Published private(set) var otherStrokes: [String: [RemoteStroke]] = [:]
    @Published private(set) var activePlaygroupId: UUID?
    @Published private(set) var currentHoleNumber: Int = 1

    /// userId of whoever just hit "push to talk", or nil. Set by inbound
    /// `talk_start` broadcast; auto-cleared after `talkAlertTTL` seconds so
    /// stale "is talking" banners don't linger if the audio never arrives.
    @Published private(set) var currentlySpeaking: String?
    static let talkAlertTTL: TimeInterval = 5
    private var talkAlertClearTask: Task<Void, Never>?

    /// Master toggle for publishing your own GPS via presence. When `false`,
    /// you still receive others' presence — you just don't broadcast yours.
    /// Persisted in UserDefaults; flipped by Settings/Options UI.
    static let liveDotsEnabledKey = "playgroup.liveDotsEnabled"
    static var liveDotsEnabled: Bool {
        get {
            // Default true — joining a playgroup implies you're sharing.
            if UserDefaults.standard.object(forKey: liveDotsEnabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: liveDotsEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: liveDotsEnabledKey) }
    }

    /// How often to push our GPS into presence. 5s is a comfortable middle —
    /// matches "live enough" for golf without hammering Realtime.
    static let presenceTickSeconds: TimeInterval = 5

    private let supabase = SupabaseManager.shared

    private var channel: RealtimeChannelV2?
    private var presenceTask: Task<Void, Never>?
    private var subscriptions: [Task<Void, Never>] = []
    private var broadcastSubscriptions: [RealtimeSubscription] = []
    private var currentUserId: String?
    /// Round ids we've already wired stroke postgres-changes for. Tracked
    /// so a mid-round joiner can be added without re-subscribing the whole
    /// channel (and without double-wiring the existing rounds).
    private var wiredRoundIds: Set<String> = []

    /// Hook the host UI installs so we can play received audio without
    /// PlaygroupChannel needing to import AVFoundation. WalkieTalkie service
    /// sets this in its init.
    var onIncomingAudio: ((URL) -> Void)?
    /// Hook the host UI installs to fire haptic + sound on inbound talk_start.
    var onTalkStartReceived: ((String) -> Void)?

    private init() {}

    // MARK: - Lifecycle

    /// Start (or restart) the channel for the given playgroup. Idempotent:
    /// no-ops if already running for this playgroup. Tears down + restarts
    /// if a different playgroup id is provided.
    func start(playgroupId: UUID, currentHole: Int, userId: String) {
        if activePlaygroupId == playgroupId { return }
        Task { await self.restart(playgroupId: playgroupId, currentHole: currentHole, userId: userId) }
    }

    /// Update the hole the user is currently playing — controls which strokes
    /// we keep loaded for other players. Cheap to call on every hole change.
    func updateCurrentHole(_ hole: Int, userId: String) {
        guard hole != currentHoleNumber else { return }
        currentHoleNumber = hole
        Task { await self.refreshOtherStrokes(userId: userId) }
    }

    func stop() {
        Task { await self.teardown() }
    }

    private func restart(playgroupId: UUID, currentHole: Int, userId: String) async {
        await teardown()
        activePlaygroupId = playgroupId
        currentHoleNumber = currentHole
        currentUserId = userId

        // Pull the current member list once for color/round-id lookup. Realtime
        // postgres-changes on playgroup_members would be a future optimization.
        do {
            members = try await PlaygroupService.shared.members(of: playgroupId)
        } catch {
            dprint("📡 [PlaygroupChannel] members fetch failed: \(error.localizedDescription)")
            members = []
        }

        let ch = supabase.realtime.channel("playgroup:\(playgroupId.uuidString)")
        channel = ch

        // Presence — receive
        let presenceStream = ch.presenceChange()
        subscriptions.append(Task { [weak self] in
            for await change in presenceStream {
                await self?.handlePresenceChange(change)
            }
        })

        // Strokes for other members' rounds — postgres-changes per round_id.
        // Filter is server-side, so we only get events for the round_ids we
        // care about (cheap — Postgres doesn't push events we'd discard).
        for m in members where m.userId != userId {
            if let roundId = m.roundId?.uuidString {
                wireStrokesForRound(ch, roundId: roundId)
            }
        }

        // Live membership: when someone joins or leaves the playgroup
        // mid-round, re-fetch members + wire up strokes for any new
        // round_ids. Without this, late joiners would be invisible until
        // the channel restarted (back out of round → re-enter).
        wireMembersChange(ch, playgroupId: playgroupId, userId: userId)

        do {
            try await ch.subscribeWithError()
        } catch {
            dprint("📡 [PlaygroupChannel] subscribe failed: \(error.localizedDescription)")
        }

        // Initial pull for other-player strokes (postgres-changes only fires
        // on changes from now on; we need the existing rows too).
        await refreshOtherStrokes(userId: userId)

        // Walkie-talkie: pre-alert via broadcast (~100-200ms latency) +
        // postgres-changes on playgroup_messages for the audio delivery row.
        wireWalkieTalkie(ch, playgroupId: playgroupId, userId: userId)

        // Start publishing our own presence on a tick.
        startPresenceTick(userId: userId)

        dprint("📡 [PlaygroupChannel] started for playgroup \(playgroupId.uuidString.prefix(8))…")
    }

    private func teardown() async {
        presenceTask?.cancel()
        presenceTask = nil
        talkAlertClearTask?.cancel()
        talkAlertClearTask = nil
        for s in subscriptions { s.cancel() }
        subscriptions.removeAll()
        for s in broadcastSubscriptions { s.cancel() }
        broadcastSubscriptions.removeAll()
        if let ch = channel {
            await ch.untrack()
            await ch.unsubscribe()
        }
        channel = nil
        activePlaygroupId = nil
        currentUserId = nil
        wiredRoundIds.removeAll()
        members = []
        presence = [:]
        otherStrokes = [:]
        currentlySpeaking = nil
    }

    // MARK: - Presence

    private func startPresenceTick(userId: String) {
        presenceTask?.cancel()
        presenceTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.publishPresenceIfEnabled(userId: userId)
                try? await Task.sleep(nanoseconds: UInt64(Self.presenceTickSeconds * 1_000_000_000))
            }
        }
    }

    private func publishPresenceIfEnabled(userId: String) async {
        guard let ch = channel else { return }
        guard Self.liveDotsEnabled else {
            // Make sure we're not still tracked from a previous session where
            // the user had it enabled.
            await ch.untrack()
            return
        }
        guard let loc = LocationManager.shared.location else { return }
        let payload: [String: AnyJSON] = [
            "user_id": .string(userId),
            "lat": .double(loc.coordinate.latitude),
            "lon": .double(loc.coordinate.longitude),
            "ts": .double(Date().timeIntervalSince1970)
        ]
        await ch.track(state: payload)
    }

    private func handlePresenceChange(_ change: any PresenceAction) async {
        // V2 SDK gives us joins + leaves keyed by an opaque presence key.
        // PresenceV2.state is the JSON object we tracked via channel.track().
        var snap: [String: MemberPresence] = presence

        for (_, p) in change.joins {
            if let mp = MemberPresence(dict: p.state) {
                snap[mp.userId] = mp
            }
        }
        for (_, p) in change.leaves {
            if case let .string(uid) = p.state["user_id"] ?? .null {
                snap.removeValue(forKey: uid)
            }
        }
        presence = snap
    }

    // MARK: - Other-player strokes

    private func refreshOtherStrokes(userId: String) async {
        let otherMembers = members.filter { $0.userId != userId }
        var byUser: [String: [RemoteStroke]] = [:]
        for m in otherMembers {
            guard let roundId = m.roundId else { continue }
            do {
                let rows: [RemoteStroke] = try await supabase.from("strokes")
                    .select()
                    .eq("round_id", value: roundId)
                    .eq("hole_number", value: currentHoleNumber)
                    .order("stroke_number")
                    .execute()
                    .value
                byUser[m.userId] = rows
            } catch {
                dprint("📡 [PlaygroupChannel] stroke fetch for \(m.userId.prefix(8))… failed: \(error.localizedDescription)")
            }
        }
        otherStrokes = byUser
    }

    /// Subscribe to playgroup_members postgres-changes for the active
    /// playgroup so mid-round joins/leaves get reflected immediately.
    /// Triggers a member refetch + wires stroke subscriptions for any
    /// newly-present round_ids.
    private func wireMembersChange(_ ch: RealtimeChannelV2, playgroupId: UUID, userId: String) {
        let pgFilter: RealtimePostgresFilter = .eq("playgroup_id", value: playgroupId.uuidString)
        let inserts = ch.postgresChange(InsertAction.self, table: "playgroup_members", filter: pgFilter)
        let deletes = ch.postgresChange(DeleteAction.self, table: "playgroup_members", filter: pgFilter)
        let updates = ch.postgresChange(UpdateAction.self, table: "playgroup_members", filter: pgFilter)
        subscriptions.append(Task { [weak self] in
            for await _ in inserts { await self?.refreshMembers(playgroupId: playgroupId, userId: userId) }
        })
        subscriptions.append(Task { [weak self] in
            for await _ in deletes { await self?.refreshMembers(playgroupId: playgroupId, userId: userId) }
        })
        subscriptions.append(Task { [weak self] in
            for await _ in updates { await self?.refreshMembers(playgroupId: playgroupId, userId: userId) }
        })
    }

    /// Refetch members + wire stroke subs for any newly-present round_ids.
    /// Removed members' stroke buckets get cleared from `otherStrokes`.
    private func refreshMembers(playgroupId: UUID, userId: String) async {
        guard let ch = channel else { return }
        do {
            let fresh = try await PlaygroupService.shared.members(of: playgroupId)
            members = fresh

            // Wire stroke subs for any new other-member round_ids.
            for m in fresh where m.userId != userId {
                if let roundId = m.roundId?.uuidString, !wiredRoundIds.contains(roundId) {
                    wireStrokesForRound(ch, roundId: roundId)
                    // Pull existing strokes for the new member's current hole
                    // so they're visible immediately, not on next stroke.
                    await refreshStrokesForMember(m)
                }
            }

            // Drop stroke caches for users who are no longer members.
            let validIds = Set(fresh.map { $0.userId })
            otherStrokes = otherStrokes.filter { validIds.contains($0.key) }
            // Likewise prune presence dots for departed members.
            presence = presence.filter { validIds.contains($0.key) }
        } catch {
            dprint("📡 [PlaygroupChannel] members refresh failed: \(error.localizedDescription)")
        }
    }

    private func refreshStrokesForMember(_ m: PlaygroupMember) async {
        guard let roundId = m.roundId else { return }
        do {
            let rows: [RemoteStroke] = try await supabase.from("strokes")
                .select()
                .eq("round_id", value: roundId)
                .eq("hole_number", value: currentHoleNumber)
                .order("stroke_number")
                .execute()
                .value
            otherStrokes[m.userId] = rows
        } catch {
            dprint("📡 [PlaygroupChannel] stroke refresh for \(m.userId.prefix(8))… failed: \(error.localizedDescription)")
        }
    }

    private func wireStrokesForRound(_ ch: RealtimeChannelV2, roundId: String) {
        wiredRoundIds.insert(roundId)
        let pgFilter: RealtimePostgresFilter = .eq("round_id", value: roundId)
        let inserts = ch.postgresChange(InsertAction.self, table: "strokes", filter: pgFilter)
        let updates = ch.postgresChange(UpdateAction.self, table: "strokes", filter: pgFilter)
        let deletes = ch.postgresChange(DeleteAction.self, table: "strokes", filter: pgFilter)
        subscriptions.append(Task { [weak self] in
            for await action in inserts { await self?.applyStrokeChange(.insert, record: action.record) }
        })
        subscriptions.append(Task { [weak self] in
            for await action in updates { await self?.applyStrokeChange(.update, record: action.record) }
        })
        subscriptions.append(Task { [weak self] in
            for await action in deletes { await self?.applyStrokeChange(.delete, record: action.oldRecord) }
        })
    }

    private enum StrokeChangeKind { case insert, update, delete }

    private func applyStrokeChange(_ kind: StrokeChangeKind, record: [String: AnyJSON]) async {
        guard let stroke = RemoteStroke(record: record) else { return }
        // Ignore strokes from holes we're not currently displaying; cheaper
        // than re-rendering for nothing.
        guard stroke.holeNumber == currentHoleNumber else { return }
        // Find which member owns this stroke. members[].roundId is our key.
        guard let owner = members.first(where: { $0.roundId == stroke.roundId })?.userId else { return }

        var bucket = otherStrokes[owner] ?? []
        switch kind {
        case .insert, .update:
            if let idx = bucket.firstIndex(where: { $0.id == stroke.id }) {
                bucket[idx] = stroke
            } else {
                bucket.append(stroke)
            }
            bucket.sort { $0.strokeNumber < $1.strokeNumber }
        case .delete:
            bucket.removeAll { $0.id == stroke.id }
        }
        otherStrokes[owner] = bucket
    }

    // MARK: - Scorecard data (multiplayer)

    /// One player's data for the multi-player scorecard view. Built from:
    /// - the local Round (when `userId == self`), or
    /// - a Realtime/PostgREST fetch of the co-member's round + strokes.
    struct ScorecardPlayer: Identifiable {
        let userId: String
        let displayName: String
        let colorHex: String
        let teeId: UUID?
        let teeName: String?
        let teeHoles: [Int: CachedCourseTeeHole]?
        let strokesByHole: [Int: Int]      // hole # → non-penalty stroke count
        let completedHoles: Set<Int>
        var id: String { userId }
    }

    /// Fetch every member's full-round scorecard payload — including the
    /// local user, so the caller doesn't have to merge sources. Each
    /// non-self fetch is cheap (one rounds row + one strokes query +
    /// optionally one tee/tee-holes lookup), and they run concurrently.
    func fetchScorecardPlayers(
        selfRound: Round,
        selfDisplayName: String,
        profileLookup: [String: UserProfile]
    ) async -> [ScorecardPlayer] {
        let myUid = currentUserId

        var players: [ScorecardPlayer] = []

        // Self — straight from local SwiftData.
        if let myUid = myUid {
            let mine = await ScorecardPlayer.fromLocalRound(
                round: selfRound,
                userId: myUid,
                displayName: selfDisplayName,
                colorHex: color(for: myUid)
            )
            players.append(mine)
        }

        // Others — concurrent fetches.
        let others = members.filter { $0.userId != myUid && $0.roundId != nil }
        await withTaskGroup(of: ScorecardPlayer?.self) { group in
            for m in others {
                let display = profileLookup[m.userId]?.resolvedName ?? "Player"
                let colorHex = m.color ?? PlaygroupService.playerPalette[0]
                let roundId = m.roundId!
                let userId = m.userId
                group.addTask { [weak self] in
                    await self?.fetchOnePlayerScorecard(
                        userId: userId,
                        roundId: roundId,
                        displayName: display,
                        colorHex: colorHex
                    )
                }
            }
            for await p in group {
                if let p = p { players.append(p) }
            }
        }

        // Stable order: host first (palette[0]), then by displayName for joiners.
        players.sort { lhs, rhs in
            if lhs.colorHex == PlaygroupService.playerPalette[0] { return true }
            if rhs.colorHex == PlaygroupService.playerPalette[0] { return false }
            return lhs.displayName < rhs.displayName
        }
        return players
    }

    private func fetchOnePlayerScorecard(
        userId: String,
        roundId: UUID,
        displayName: String,
        colorHex: String
    ) async -> ScorecardPlayer? {
        struct RoundRow: Decodable {
            let id: UUID
            let selected_tee_id: UUID?
            let completed_holes: [Int]?
        }
        do {
            let rows: [RoundRow] = try await supabase.from("rounds")
                .select("id,selected_tee_id,completed_holes")
                .eq("id", value: roundId)
                .limit(1)
                .execute()
                .value
            guard let row = rows.first else { return nil }

            let strokes: [RemoteStroke] = try await supabase.from("strokes")
                .select()
                .eq("round_id", value: roundId)
                .order("hole_number")
                .execute()
                .value

            var byHole: [Int: Int] = [:]
            for s in strokes where !s.isPenalty {
                byHole[s.holeNumber, default: 0] += 1
            }

            // Tee data — only loaded when present.
            var teeName: String? = nil
            var teeHoles: [Int: CachedCourseTeeHole]? = nil
            if let teeId = row.selected_tee_id {
                let holes = try await GolfCourseAPIService.shared.cachedHoles(forTeeId: teeId)
                let tees: [CachedCourseTee] = try await supabase.from("course_tees")
                    .select()
                    .eq("id", value: teeId)
                    .limit(1)
                    .execute()
                    .value
                teeName = tees.first?.teeName
                var map: [Int: CachedCourseTeeHole] = [:]
                for h in holes { map[h.holeNumber] = h }
                teeHoles = map
            }

            return ScorecardPlayer(
                userId: userId,
                displayName: displayName,
                colorHex: colorHex,
                teeId: row.selected_tee_id,
                teeName: teeName,
                teeHoles: teeHoles,
                strokesByHole: byHole,
                completedHoles: Set(row.completed_holes ?? [])
            )
        } catch {
            dprint("📡 [PlaygroupChannel] scorecard fetch for \(userId.prefix(8))… failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Color lookup

    func color(for userId: String) -> String {
        members.first(where: { $0.userId == userId })?.color
            ?? PlaygroupService.playerPalette[0]
    }

    // MARK: - Walkie-talkie

    private func wireWalkieTalkie(_ ch: RealtimeChannelV2, playgroupId: UUID, userId: String) {
        // Inbound pre-alert. Self-broadcasts come back too — filter ourself out.
        let talkSub = ch.onBroadcast(event: "talk_start") { [weak self] payload in
            guard case let .string(senderId) = payload["sender_id"] ?? .null else { return }
            guard senderId != userId else { return }
            Task { @MainActor [weak self] in
                self?.handleTalkStart(senderId: senderId)
            }
        }
        broadcastSubscriptions.append(talkSub)

        // Inbound voice clip — single binary broadcast carrying the entire
        // AAC blob. Server-side fan-out, NOT persisted anywhere — when the
        // packet leaves the channel state, it's gone. We deliberately do
        // NOT use Storage or a delivery-row table here: voice messages are
        // ephemeral by design, and a 5–30s AAC clip @ 16kbps fits well
        // inside the 256KB-per-message broadcast cap.
        let voiceSub = ch.onBroadcastData(event: "voice") { [weak self] data in
            Task { @MainActor [weak self] in
                self?.handleIncomingVoice(data)
            }
        }
        broadcastSubscriptions.append(voiceSub)
    }

    private func handleTalkStart(senderId: String) {
        currentlySpeaking = senderId
        onTalkStartReceived?(senderId)
        talkAlertClearTask?.cancel()
        talkAlertClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.talkAlertTTL * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.currentlySpeaking = nil }
        }
    }

    private func handleIncomingVoice(_ data: Data) {
        // Self-broadcasts also fan back out. The audio bytes themselves
        // don't carry sender info, so we rely on the immediately-prior
        // `talk_start` broadcast (which IS sender-id-tagged) to know
        // who's speaking. To suppress our own loopback playback, we skip
        // any voice payload received while we ourselves are recording.
        if WalkieTalkie.shared.isRecording { return }
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m4a")
        do {
            try data.write(to: tmpURL)
            onIncomingAudio?(tmpURL)
        } catch {
            dprint("📡 [PlaygroupChannel] voice write failed: \(error.localizedDescription)")
        }
    }

    /// Fire the pre-alert broadcast so other watches haptic+ding the moment
    /// the talk button is pressed, before the audio is even recorded.
    func broadcastTalkStart() async {
        guard let ch = channel, let uid = currentUserId else { return }
        let payload: JSONObject = ["sender_id": .string(uid)]
        await ch.broadcast(event: "talk_start", message: payload)
    }

    /// Send the recorded audio as a single binary broadcast on the playgroup
    /// channel. NOT persisted anywhere — once the packet has been fanned out
    /// to currently-connected co-members, it's gone. Late-joiners will not
    /// hear messages they missed (this is intentional walkie-talkie semantics).
    /// 256KB cap per message; well above the ~60KB needed for a 30s clip.
    func sendVoiceMessage(localFile: URL, durationMs: Int) async {
        guard let ch = channel else { return }
        defer { try? FileManager.default.removeItem(at: localFile) }
        do {
            let data = try Data(contentsOf: localFile)
            await ch.broadcast(event: "voice", data: data)
        } catch {
            dprint("📡 [PlaygroupChannel] sendVoiceMessage failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Wire types

// MARK: - ScorecardPlayer self-construction from local Round

extension PlaygroupChannel.ScorecardPlayer {
    /// Build the self row for the multiplayer scorecard from the local
    /// SwiftData Round we already have in memory. Pulls tee data via
    /// GolfCourseAPIService cache, same path the solo scorecard uses.
    static func fromLocalRound(
        round: Round,
        userId: String,
        displayName: String,
        colorHex: String
    ) async -> PlaygroupChannel.ScorecardPlayer {
        var strokesByHole: [Int: Int] = [:]
        for s in round.strokes where !s.isPenalty {
            strokesByHole[s.holeNumber, default: 0] += 1
        }
        let completed = Set(round.completedHolesArray)

        var teeName: String? = nil
        var teeHoles: [Int: CachedCourseTeeHole]? = nil
        if let teeId = round.selectedTeeId {
            do {
                let holes = try await GolfCourseAPIService.shared.cachedHoles(forTeeId: teeId)
                let tees: [CachedCourseTee] = try await SupabaseManager.shared.from("course_tees")
                    .select()
                    .eq("id", value: teeId)
                    .limit(1)
                    .execute()
                    .value
                teeName = tees.first?.teeName
                var map: [Int: CachedCourseTeeHole] = [:]
                for h in holes { map[h.holeNumber] = h }
                teeHoles = map
            } catch {
                // Fall through with nil tee data — scorecard handles that.
            }
        }

        return PlaygroupChannel.ScorecardPlayer(
            userId: userId,
            displayName: displayName,
            colorHex: colorHex,
            teeId: round.selectedTeeId,
            teeName: teeName,
            teeHoles: teeHoles,
            strokesByHole: strokesByHole,
            completedHoles: completed
        )
    }
}

/// Snapshot of a co-member's last-published GPS.
struct MemberPresence: Equatable {
    let userId: String
    let lat: Double
    let lon: Double
    let ts: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    init?(dict: [String: AnyJSON]) {
        guard
            case let .string(userId)? = dict["user_id"],
            case let .double(lat)? = dict["lat"],
            case let .double(lon)? = dict["lon"]
        else { return nil }
        self.userId = userId
        self.lat = lat
        self.lon = lon
        if case let .double(ts)? = dict["ts"] {
            self.ts = Date(timeIntervalSince1970: ts)
        } else {
            self.ts = Date()
        }
    }
}

/// In-memory representation of another player's stroke. Not @Model on
/// purpose — these strokes belong to rounds the local user does not own.
struct RemoteStroke: Identifiable, Decodable, Hashable {
    let id: UUID
    let roundId: UUID
    let holeNumber: Int
    let strokeNumber: Int
    let latitude: Double
    let longitude: Double
    let isPenalty: Bool

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case roundId = "round_id"
        case holeNumber = "hole_number"
        case strokeNumber = "stroke_number"
        case latitude
        case longitude
        case isPenalty = "is_penalty"
    }

    /// Build from a Realtime record payload (AnyJSON dict). Used by the
    /// postgres-changes apply path where we don't have a Decoder handy.
    init?(record: [String: AnyJSON]) {
        guard
            case let .string(idStr)? = record["id"], let id = UUID(uuidString: idStr),
            case let .string(roundIdStr)? = record["round_id"], let roundId = UUID(uuidString: roundIdStr)
        else { return nil }

        func intVal(_ key: String) -> Int? {
            switch record[key] {
            case .integer(let i)?: return i
            case .double(let d)?: return Int(d)
            default: return nil
            }
        }
        func dblVal(_ key: String) -> Double? {
            switch record[key] {
            case .double(let d)?: return d
            case .integer(let i)?: return Double(i)
            default: return nil
            }
        }

        guard let holeNumber = intVal("hole_number"),
              let strokeNumber = intVal("stroke_number"),
              let lat = dblVal("latitude"),
              let lon = dblVal("longitude") else { return nil }

        self.id = id
        self.roundId = roundId
        self.holeNumber = holeNumber
        self.strokeNumber = strokeNumber
        self.latitude = lat
        self.longitude = lon
        if case let .bool(b)? = record["is_penalty"] {
            self.isPenalty = b
        } else {
            self.isPenalty = false
        }
    }
}
