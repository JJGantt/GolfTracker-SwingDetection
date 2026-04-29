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

    var body: some View {
        ScorecardView(round: round, teeHoles: teeHoles, teeName: teeName)
            .task(id: round.selectedTeeId) {
                guard !loaded else { return }
                guard let teeId = round.selectedTeeId else {
                    loaded = true
                    return
                }
                do {
                    // Per-hole scorecard data + tee name lookup, both via the
                    // shared GolfCourseAPIService / SupabaseManager.
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
    }
}
