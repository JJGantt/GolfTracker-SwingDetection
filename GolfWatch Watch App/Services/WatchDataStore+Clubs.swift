import Foundation
import SwiftData

// The club catalog on the watch: hydrated from Supabase into SwiftData and
// cached for the crown.
extension WatchDataStore {

    func hydrateClubsFromSupabase() {
        Task { [weak self] in
            guard let self = self else { return }
            guard let context = self.context else { return }
            guard WatchAuthSession.shared.currentUserId != nil else { return }
            let supabase = SupabaseManager.shared
            do {
                async let typesAsync: [ClubTypeDTO] = supabase.from("club_types").select().execute().value
                async let clubsAsync: [ClubDTO] = supabase.from("clubs").select().execute().value
                async let setsAsync: [ClubSetDTO] = supabase.from("club_sets").select().execute().value
                // ClubSet.typeSelections lives in a separate join table on
                // Supabase (one row per type per set). We fetch it here so
                // we can populate the local ClubSet's typeSelections array
                // — without this the watch sees an empty active set and
                // the crown filters to zero clubs.
                async let selectionsAsync: [ClubSetTypeSelectionDTO] = supabase.from("club_set_type_selections").select().execute().value
                let (types, clubs, sets, selections) = try await (typesAsync, clubsAsync, setsAsync, selectionsAsync)
                await MainActor.run {
                    // Supabase is the source of truth for clubs/types/sets
                    // on the watch. Insert/update for everything we just
                    // fetched, then DELETE any local row whose id isn't in
                    // the fetched set. Without this, leftover rows from
                    // earlier app versions (pre-Supabase-sync) accumulate
                    // alongside the synced ones, producing duplicates.
                    let fetchedTypeIds = Set(types.map(\.id))
                    let fetchedClubIds = Set(clubs.map(\.id))
                    let fetchedSetIds  = Set(sets.map(\.id))

                    for t in types { Self.upsertClubType(t, into: context) }
                    for c in clubs { Self.upsertClub(c, into: context) }
                    // Group selections by club_set_id so we can attach them
                    // to each set as we upsert it.
                    let selectionsBySetId = Dictionary(grouping: selections, by: { $0.club_set_id })
                    for s in sets {
                        Self.upsertClubSet(s, selections: selectionsBySetId[s.id] ?? [], into: context)
                    }

                    // Prune local-only entries.
                    if let existingTypes = try? context.fetch(FetchDescriptor<ClubTypeData>()) {
                        for t in existingTypes where !fetchedTypeIds.contains(t.id) {
                            context.delete(t)
                        }
                    }
                    if let existingClubs = try? context.fetch(FetchDescriptor<ClubData>()) {
                        for c in existingClubs where !fetchedClubIds.contains(c.id) {
                            context.delete(c)
                        }
                    }
                    if let existingSets = try? context.fetch(FetchDescriptor<ClubSet>()) {
                        for s in existingSets where !fetchedSetIds.contains(s.id) {
                            context.delete(s)
                        }
                    }

                    try? context.save()
                    // Republish the cached arrays so views pick up new clubs.
                    self.refreshClubsCache()
                    self.objectWillChange.send()
                    dprint("⌚ [WatchDataStore] hydrated \(types.count) types / \(clubs.count) clubs / \(sets.count) sets (pruned local-only rows)")
                }
            } catch {
                dprint("⌚ [WatchDataStore] hydrate failed: \(error.localizedDescription)")
            }
        }
    }

    private static func upsertClubType(_ t: ClubTypeDTO, into context: ModelContext) {
        let id = t.id
        let descriptor = FetchDescriptor<ClubTypeData>(predicate: #Predicate { $0.id == id })
        if let existing = (try? context.fetch(descriptor))?.first {
            existing.name = t.name
            existing.isDefault = t.is_default ?? false
            existing.averageDistance = t.average_distance
            existing.sortOrder = t.sort_order
        } else {
            context.insert(ClubTypeData(id: id, name: t.name, isDefault: t.is_default ?? false, averageDistance: t.average_distance, sortOrder: t.sort_order))
        }
    }

    private static func upsertClub(_ c: ClubDTO, into context: ModelContext) {
        let id = c.id
        let descriptor = FetchDescriptor<ClubData>(predicate: #Predicate { $0.id == id })
        if let existing = (try? context.fetch(descriptor))?.first {
            existing.name = c.name
            existing.clubTypeId = c.club_type_id
            existing.isDefault = c.is_default ?? false
        } else {
            context.insert(ClubData(id: id, name: c.name, clubTypeId: c.club_type_id, isDefault: c.is_default ?? false))
        }
    }

    private static func upsertClubSet(_ s: ClubSetDTO, selections: [ClubSetTypeSelectionDTO], into context: ModelContext) {
        let id = s.id
        let descriptor = FetchDescriptor<ClubSet>(predicate: #Predicate { $0.id == id })
        let dc = s.date_created.flatMap(Self.parseISO) ?? Date()
        let dm = s.date_modified.flatMap(Self.parseISO) ?? Date()
        let typeSelections = selections.map { TypeSelection(typeId: $0.type_id, activeClubId: $0.active_club_id) }
        if let existing = (try? context.fetch(descriptor))?.first {
            existing.name = s.name
            existing.isActive = s.is_active ?? false
            existing.dateCreated = dc
            existing.dateModified = dm
            existing.typeSelections = typeSelections
        } else {
            context.insert(ClubSet(id: id, name: s.name, typeSelections: typeSelections, isActive: s.is_active ?? false, dateCreated: dc, dateModified: dm))
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static func parseISO(_ s: String) -> Date? {
        if let d = isoFormatter.date(from: s) { return d }
        let alt = ISO8601DateFormatter(); alt.formatOptions = [.withInternetDateTime]
        return alt.date(from: s)
    }

    var activeSetClubs: [ClubData] {
        guard let activeSet = clubSets.first(where: { $0.isActive }) else {
            return availableClubs
        }
        // Safety net: if the active set has no typeSelections (e.g. join
        // table fetch failed, or hydrate happened before the selections
        // were available), fall back to the full catalog rather than
        // showing zero clubs in the crown.
        if activeSet.typeSelections.isEmpty {
            return availableClubs
        }
        // Order: follow the type order from clubTypes (Drive → Putt) rather
        // than typeSelections' internal order, so the crown has a stable,
        // predictable progression.
        let typeOrder = clubTypes.map(\.id)
        let selectionsByType = Dictionary(uniqueKeysWithValues:
            activeSet.typeSelections.map { ($0.typeId, $0.activeClubId) }
        )
        let mapped = typeOrder.compactMap { typeId -> ClubData? in
            guard let activeClubId = selectionsByType[typeId] ?? nil else { return nil }
            return availableClubs.first { $0.id == activeClubId }
        }
        // Same safety net at the result level — prevents a sparse / broken
        // selection from silently emptying the crown.
        return mapped.isEmpty ? availableClubs : mapped
    }
}
