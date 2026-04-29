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
        let otherRoundIds = members
            .filter { $0.userId != userId }
            .compactMap { $0.roundId?.uuidString }
        for roundId in otherRoundIds {
            wireStrokesForRound(ch, roundId: roundId)
        }

        await ch.subscribe()

        // Initial pull for other-player strokes (postgres-changes only fires
        // on changes from now on; we need the existing rows too).
        await refreshOtherStrokes(userId: userId)

        // Start publishing our own presence on a tick.
        startPresenceTick(userId: userId)

        dprint("📡 [PlaygroupChannel] started for playgroup \(playgroupId.uuidString.prefix(8))…")
    }

    private func teardown() async {
        presenceTask?.cancel()
        presenceTask = nil
        for s in subscriptions { s.cancel() }
        subscriptions.removeAll()
        if let ch = channel {
            try? await ch.untrack()
            await ch.unsubscribe()
        }
        channel = nil
        activePlaygroupId = nil
        members = []
        presence = [:]
        otherStrokes = [:]
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
            try? await ch.untrack()
            return
        }
        guard let loc = LocationManager.shared.location else { return }
        let payload: [String: AnyJSON] = [
            "user_id": .string(userId),
            "lat": .double(loc.coordinate.latitude),
            "lon": .double(loc.coordinate.longitude),
            "ts": .double(Date().timeIntervalSince1970)
        ]
        try? await ch.track(state: payload)
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

    private func wireStrokesForRound(_ ch: RealtimeChannelV2, roundId: String) {
        let inserts = ch.postgresChange(InsertAction.self, table: "strokes", filter: "round_id=eq.\(roundId)")
        let updates = ch.postgresChange(UpdateAction.self, table: "strokes", filter: "round_id=eq.\(roundId)")
        let deletes = ch.postgresChange(DeleteAction.self, table: "strokes", filter: "round_id=eq.\(roundId)")
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

    // MARK: - Color lookup

    func color(for userId: String) -> String {
        members.first(where: { $0.userId == userId })?.color
            ?? PlaygroupService.playerPalette[0]
    }
}

// MARK: - Wire types

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
