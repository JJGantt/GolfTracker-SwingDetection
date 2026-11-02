import Foundation

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
}
