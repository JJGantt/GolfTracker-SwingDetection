import Foundation
import SwiftData

// Club types, clubs and club sets on the phone: the bag the user edits, kept
// in SwiftData and mirrored to Supabase.
extension DataStore {

    // MARK: - Club Type Management

    /// New user-created type. Lands at the end of the bag; the user drags it
    /// where they want it, and that position sticks.
    func addClubType(name: String) {
        let nextOrder = (clubTypes.compactMap(\.sortOrder).max() ?? -1) + 1
        let clubType = ClubTypeData(name: name, isDefault: false, sortOrder: nextOrder)
        clubTypes.append(clubType)
        saveClubTypes()
        dprint("🏌️ Added club type: \(name), total types: \(clubTypes.count)")
    }

    func deleteClubType(_ clubType: ClubTypeData) {
        // Don't allow deleting default types
        guard !clubType.isDefault else { return }

        let removedClubIds = availableClubs.filter { $0.clubTypeId == clubType.id }.map { $0.id }
        clubTypes.removeAll { $0.id == clubType.id }

        // Remove all clubs that use this type
        availableClubs.removeAll { $0.clubTypeId == clubType.id }

        saveClubTypes()
        saveClubs()
        SupabaseSync.shared.deleteClubType(id: clubType.id)
        for id in removedClubIds { SupabaseSync.shared.deleteClub(id: id) }
    }

    func updateClubType(_ clubType: ClubTypeData, name: String) {
        guard let index = clubTypes.firstIndex(where: { $0.id == clubType.id }) else { return }
        clubTypes[index].name = name
        saveClubTypes()
    }

    /// Drag-to-reorder from the club-type list. Renumbers `sortOrder` across
    /// the whole array and pushes it up — before this persisted, the drag
    /// mutated the in-memory array only and the arrangement evaporated on the
    /// next SwiftData fetch.
    func moveClubType(from source: IndexSet, to destination: Int) {
        clubTypes.move(fromOffsets: source, toOffset: destination)
        clubTypes.renumberBagOrder()
        saveClubTypes()
        for t in clubTypes { SupabaseSync.shared.upsertClubType(t) }
    }

    // MARK: - Club Management

    func addCustomClub(name: String, clubTypeId: UUID) {
        let club = ClubData(name: name, clubTypeId: clubTypeId, isDefault: false)
        availableClubs.append(club)
        saveClubs()
    }

    func addCustomClubReturningId(name: String, clubTypeId: UUID) -> UUID {
        let club = ClubData(name: name, clubTypeId: clubTypeId, isDefault: false)
        availableClubs.append(club)
        saveClubs()
        return club.id
    }

    func updateClub(_ club: ClubData, name: String, clubTypeId: UUID) {
        guard let index = availableClubs.firstIndex(where: { $0.id == club.id }) else { return }
        availableClubs[index].name = name
        availableClubs[index].clubTypeId = clubTypeId
        saveClubs()
    }

    func moveClub(from source: IndexSet, to destination: Int) {
        availableClubs.move(fromOffsets: source, toOffset: destination)
        saveClubs()
    }

    func deleteClub(_ club: ClubData) {
        // Don't allow deleting default clubs
        guard !club.isDefault else { return }

        availableClubs.removeAll { $0.id == club.id }

        // Clear active club in any sets that used this club
        for i in 0..<clubSets.count {
            for j in 0..<clubSets[i].typeSelections.count {
                if clubSets[i].typeSelections[j].activeClubId == club.id {
                    clubSets[i].typeSelections[j].activeClubId = nil
                }
            }
        }

        saveClubs()
        saveClubSets()
        SupabaseSync.shared.deleteClub(id: club.id)
    }

    func getClubs(forType typeId: UUID) -> [ClubData] {
        return availableClubs.filter { $0.clubTypeId == typeId }
    }

    // MARK: - Club Set Management

    func addClubSet(name: String, typeSelections: [TypeSelection]) {
        let clubSet = ClubSet(name: name, typeSelections: typeSelections, isActive: false)
        clubSets.append(clubSet)
        saveClubSets()
    }

    func updateClubSet(_ clubSet: ClubSet, name: String, typeSelections: [TypeSelection]) {
        guard let index = clubSets.firstIndex(where: { $0.id == clubSet.id }) else { return }

        clubSets[index].name = name
        clubSets[index].typeSelections = typeSelections
        clubSets[index].dateModified = Date()
        saveClubSets()
    }

    func setActiveClubForType(in clubSet: ClubSet, typeId: UUID, clubId: UUID?) {
        guard let setIndex = clubSets.firstIndex(where: { $0.id == clubSet.id }),
              let typeIndex = clubSets[setIndex].typeSelections.firstIndex(where: { $0.typeId == typeId }) else { return }

        clubSets[setIndex].typeSelections[typeIndex].activeClubId = clubId
        clubSets[setIndex].dateModified = Date()
        saveClubSets()
    }

    func deleteClubSet(_ clubSet: ClubSet) {
        clubSets.removeAll { $0.id == clubSet.id }
        saveClubSets()
        SupabaseSync.shared.deleteClubSet(id: clubSet.id)
    }

    func setActiveClubSet(_ clubSet: ClubSet) {
        for i in 0..<clubSets.count {
            clubSets[i].isActive = false
        }

        if let index = clubSets.firstIndex(where: { $0.id == clubSet.id }) {
            clubSets[index].isActive = true
        }

        saveClubSets()
    }

    var activeClubSet: ClubSet? {
        return clubSets.first { $0.isActive }
    }

    func getTypesInActiveSet() -> [ClubTypeData] {
        guard let activeSet = activeClubSet else { return [] }
        return activeSet.typeSelections.compactMap { selection in
            clubTypes.first { $0.id == selection.typeId }
        }
    }

    func getActiveClubForType(_ typeId: UUID) -> ClubData? {
        guard let activeSet = activeClubSet,
              let clubId = activeSet.getActiveClubId(for: typeId) else { return nil }
        return availableClubs.first { $0.id == clubId }
    }

    /// Returns only the clubs that are active in the current club set
    /// This filters to clubs where the type is in the set AND has an active club selected
    func getClubsInActiveSet() -> [ClubData] {
        guard let activeSet = activeClubSet else { return [] }
        return activeSet.typeSelections.compactMap { selection in
            guard let clubId = selection.activeClubId else { return nil }
            return availableClubs.first { $0.id == clubId }
        }
    }

    /// Returns the club types that are in the active set AND have an active club selected
    /// This is used for club selection UI during rounds
    func getTypesWithActiveClubs() -> [ClubTypeData] {
        guard let activeSet = activeClubSet else { return [] }
        return activeSet.typeSelections.compactMap { selection in
            // Only include types that have an active club selected
            guard selection.activeClubId != nil else { return nil }
            return clubTypes.first { $0.id == selection.typeId }
        }
    }

    // MARK: - Loading, saving and the first-launch reconcile

    /// Async reconciliation between local SwiftData and Supabase for the
    /// clubs/types/sets catalog. Runs once at startup. Three branches:
    ///   1. Local already populated → nothing to do.
    ///   2. Local empty + Supabase populated → hydrate from Supabase.
    ///   3. Local empty + Supabase empty → seed fresh defaults locally and
    ///      push to Supabase. This is the only path that creates new rows.
    func reconcileClubsWithSupabase() async {
        // Already have a local catalog — assume it's authoritative.
        let hasLocalCatalog = !clubTypes.isEmpty && !availableClubs.isEmpty && !clubSets.isEmpty
        if hasLocalCatalog { return }
        // Not signed in — defer (sign-in handler can re-trigger via
        // configure, or we can revisit if the auth flow needs an explicit
        // hook here).
        guard AuthManager.shared.currentUserId != nil else { return }
        let supabase = SupabaseManager.shared
        do {
            async let typesAsync: [ClubTypeDTO] = supabase.from("club_types").select().execute().value
            async let clubsAsync: [ClubDTO] = supabase.from("clubs").select().execute().value
            async let setsAsync: [ClubSetDTO] = supabase.from("club_sets").select().execute().value
            // Selections live in a join table (not a column on club_sets).
            // Fetch them so the rebuilt local ClubSet has its full
            // typeSelections array — otherwise the watch's active-set
            // filter resolves to an empty crown.
            async let selectionsAsync: [ClubSetTypeSelectionDTO] = supabase.from("club_set_type_selections").select().execute().value
            let (remoteTypes, remoteClubs, remoteSets, remoteSelections) = try await (typesAsync, clubsAsync, setsAsync, selectionsAsync)

            if !remoteTypes.isEmpty || !remoteClubs.isEmpty || !remoteSets.isEmpty {
                // Branch 2: Supabase has data → hydrate locally.
                await MainActor.run {
                    hydrateClubsFromRemote(types: remoteTypes, clubs: remoteClubs, sets: remoteSets, selections: remoteSelections)
                }
            } else {
                // Branch 3: Both empty → seed fresh defaults once.
                await MainActor.run {
                    seedDefaultCatalog()
                }
            }
        } catch {
            dprint("📱 [DataStore] club reconcile failed: \(error.localizedDescription)")
        }
    }

    /// Insert remote DTOs into local SwiftData. Idempotent — upserts by id.
    private func hydrateClubsFromRemote(types: [ClubTypeDTO], clubs: [ClubDTO], sets: [ClubSetDTO], selections: [ClubSetTypeSelectionDTO]) {
        guard let context = context else { return }
        for t in types {
            let id = t.id
            let descriptor = FetchDescriptor<ClubTypeData>(predicate: #Predicate { $0.id == id })
            if (try? context.fetch(descriptor))?.first == nil {
                context.insert(ClubTypeData(id: id, name: t.name, isDefault: t.is_default ?? false, averageDistance: t.average_distance, sortOrder: t.sort_order))
            }
        }
        for c in clubs {
            let id = c.id
            let descriptor = FetchDescriptor<ClubData>(predicate: #Predicate { $0.id == id })
            if (try? context.fetch(descriptor))?.first == nil {
                context.insert(ClubData(id: id, name: c.name, clubTypeId: c.club_type_id, isDefault: c.is_default ?? false))
            }
        }
        let selectionsBySetId = Dictionary(grouping: selections, by: { $0.club_set_id })
        for s in sets {
            let id = s.id
            let descriptor = FetchDescriptor<ClubSet>(predicate: #Predicate { $0.id == id })
            let typeSels = (selectionsBySetId[id] ?? []).map {
                TypeSelection(typeId: $0.type_id, activeClubId: $0.active_club_id)
            }
            if let existing = (try? context.fetch(descriptor))?.first {
                existing.typeSelections = typeSels
            } else {
                let dc = s.date_created.flatMap(Self.parseISODate) ?? Date()
                let dm = s.date_modified.flatMap(Self.parseISODate) ?? Date()
                context.insert(ClubSet(id: id, name: s.name, typeSelections: typeSels, isActive: s.is_active ?? false, dateCreated: dc, dateModified: dm))
            }
        }
        try? context.save()
        loadClubTypes()
        loadClubs()
        loadClubSets()
        objectWillChange.send()
    }

    /// One-time seed of the default 16 club types + a single default ClubData
    /// per type + one ClubSet that uses them as the active selection. Only
    /// runs when both local SwiftData AND Supabase are empty for the user.
    private func seedDefaultCatalog() {
        clubTypes = ClubTypeData.defaultClubTypes()
        saveClubTypes()
        for clubType in clubTypes {
            let club = ClubData(name: "Default", clubTypeId: clubType.id, isDefault: true)
            availableClubs.append(club)
        }
        saveClubs()
        let typeSelections = clubTypes.map { clubType -> TypeSelection in
            let defaultClub = availableClubs.first(where: { $0.clubTypeId == clubType.id })
            return TypeSelection(typeId: clubType.id, activeClubId: defaultClub?.id)
        }
        let defaultSet = ClubSet(name: "Default Set", typeSelections: typeSelections, isActive: true)
        clubSets.append(defaultSet)
        saveClubSets()
        objectWillChange.send()
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static func parseISODate(_ s: String) -> Date? {
        if let d = isoFormatter.date(from: s) { return d }
        let alt = ISO8601DateFormatter()
        alt.formatOptions = [.withInternetDateTime]
        return alt.date(from: s)
    }

    func loadClubTypes() {
        guard let context = context else { return }
        // Bag order at the load site, so every consumer (Stats, club-set
        // editor, prediction, watch crown) inherits one order for free.
        clubTypes = ((try? context.fetch(FetchDescriptor<ClubTypeData>())) ?? []).inBagOrder()
        // Backfill: types that predate `sortOrder` (or arrived from a device
        // that never set it) land in canonical position above, then get
        // stamped so the order is authoritative from here on. One-time —
        // `renumberBagOrder` reports no change once everything is numbered.
        if clubTypes.renumberBagOrder() {
            try? context.save()
            for t in clubTypes { SupabaseSync.shared.upsertClubType(t) }
        }
    }

    func saveClubTypes() {
        guard let context = context else { return }
        for t in clubTypes where t.modelContext == nil { context.insert(t) }
        try? context.save()
        for t in clubTypes { SupabaseSync.shared.upsertClubType(t) }
    }

    func loadClubs() {
        guard let context = context else { return }
        availableClubs = (try? context.fetch(FetchDescriptor<ClubData>())) ?? []
    }

    func loadClubSets() {
        guard let context = context else { return }
        clubSets = (try? context.fetch(FetchDescriptor<ClubSet>())) ?? []
    }

    func saveClubs() {
        guard let context = context else { return }
        for c in availableClubs where c.modelContext == nil { context.insert(c) }
        try? context.save()
        for c in availableClubs { SupabaseSync.shared.upsertClub(c) }
    }

    func saveClubSets() {
        guard let context = context else { return }
        for s in clubSets where s.modelContext == nil { context.insert(s) }
        try? context.save()
        for s in clubSets { SupabaseSync.shared.upsertClubSet(s) }
    }
}
