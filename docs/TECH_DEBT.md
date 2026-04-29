# Tech Debt / Known Suboptimal Patterns

Things we built deliberately but plan to revisit when justified. Not bugs — known shortcuts with known reasons.

---

## RealtimeSync.apply fires `objectWillChange` on the entire DataStore

**Where:** `GolfTracker/Services/RealtimeSync.swift`, end of `apply(table:kind:record:)`.

**What it does:** after every postgres-changes event lands and is applied to SwiftData, fires `objectWillChange.send()` on the platform DataStore singleton (`WatchDataStore.shared` on watchOS, `DataStore.shared` on iOS). This makes every SwiftUI view observing `store` re-evaluate its body.

**Why it's there:** without it, cross-device updates didn't trigger view re-renders. Example: change holes on the iPhone → DB updated via SupabaseSync → Realtime echoes to watch → `applyRound` mutates the local SwiftData `Round.currentHoleIndex` → but the watch's `ActiveRoundView` reads `store.currentRound?.currentHoleIndex` (where `currentRound` is a computed property), and without a publisher firing, SwiftUI never re-evaluates the view.

**Why it's suboptimal:**
- Fires for *every* table change, including tables the visible view doesn't care about (`clubs`, `club_types`, `club_sets`, `courses`).
- Causes SwiftUI to re-evaluate every observing view's body on each event. Most re-evaluations produce identical output and SwiftUI throws them away during diffing — the cost is just the diff machinery running more often than necessary, not actual redraws.
- Cross-user / cross-device effect: **none**. It only signals views on the device that received the event. Doesn't broadcast, doesn't network, doesn't touch other players.

**Three ways to fix when we get to it (cost ascending):**
1. **Filter by table name** — only fire for `rounds` / `holes` / `strokes` / `targets` / `round_holes`, skip the rest. ~5 minute change, ~50% noise reduction.
2. **Rip out store-level `objectWillChange` for these mutations entirely** — pass the `Round` directly into `ActiveRoundView` as a `@Bindable` parameter and rely on SwiftData's own `@Model` observation. Cleaner architecture but touches a couple of files and risks missing a binding spot (resulting in *no* update at all). Needs on-device verification.
3. **Convert all round-related views to `@Query`-driven SwiftData fetches** — most idiomatic SwiftData pattern, but real refactor across many view files.

**Decision rule:** leave alone until we feel actual UI jank during a real multiplayer round. If everything feels fine on hardware, the sledgehammer is academic. If it doesn't, do option 2.

**Origin:** introduced 2026-04-29 in commit `11cdaab` as the fix for cross-device hole-index updates not propagating visually.
