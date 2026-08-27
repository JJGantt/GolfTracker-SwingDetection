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

---

## Cross-search GolfCourseAPI cache (deferred)

**Where:** `supabase/functions/golfcourse-search/index.ts`, `RoundResolver.searchScorecard`.

**What's deferred:** caching the *coords* and *names* of every course returned by every GolfCourseAPI search, so a future user at one of those courses can skip the live search call entirely.

**Current behavior:** the Edge Function caches per-tee scorecard data (`course_tees` + `course_tee_holes`) as a side effect of every search, but throws away the per-course `location.latitude/longitude`. The resolver always issues a live `searchCourses(query)` call when it doesn't already know `external_course_id`. The pre-cached tees only help once the resolver has independently determined which `external_course_id` to use — they save the per-tee writeback, not the search call itself.

**The optimization (when picked up):**
1. New table `golfcourse_api_courses` — one row per `external_course_id` ever returned: `external_course_id (pk)`, `name`, `latitude`, `longitude`, `fetched_at`.
2. Edge Function writes one row per `APICourse` in every response, alongside the existing tee writes.
3. Resolver's `searchScorecard` first does a proximity query against this table (1500m threshold — see "OSM ↔ GCAPI coord drift" below). On hit, use the cached `external_course_id` and fall through to the existing `cachedTees(forExternalCourseId:)` fast path; skip the Edge Function call entirely. On miss, invoke the Edge Function as today.

**Result:** API call count → 1 per *distinct name search* (not per course / not per user / not per round). After a few months, hot cache covers most courses, near-zero API spend.

**Why deferred:** the bigger correctness issue (multi-course resort name pairing — see below) needs to be solved first; the API-cost optimization is meaningless if we're pairing the wrong GCAPI course to the wrong OSM polygon at a resort.

---

## OSM ↔ GolfCourseAPI pairing at multi-course resorts

**Where:** `RoundResolver.searchScorecard` (the proximity-only filter logic).

**The problem:** when resolving an OSM-discovered course via the GolfCourseAPI miss path, the resolver currently picks the GCAPI result whose `location.latitude/longitude` is closest to the OSM polygon's centroid (within a 1500m radius). At a resort like Pinehurst, Bandon, or Bethpage, this breaks down: 5+ courses share one campus, GCAPI's per-course coords are typically all the clubhouse / address geocode (so they cluster within ~100m of each other), and "closest by distance" becomes effectively arbitrary across siblings. A user picking "Pinehurst No. 2" via the OSM picker can end up bound to "No. 4"'s scorecard.

**Concrete data — Hyde Park JAX (single-course property, works fine today):**
- OSM polygon centroid:    `30.2872613, -81.7478715`
- GolfCourseAPI location:  `30.284891,  -81.747284`
- delta: ~269m (typical clubhouse-vs-property-centroid offset)

**Resort failure mode:** at Pinehurst the four-or-five GCAPI rows for the resort would all be within ~200m of each other, and they'd all be within 1500m of every OSM polygon on the property. Distance alone cannot disambiguate. Today's resolver picks the (deterministic-but-meaningless) closest one.

**The fix when picked up:**

1. **Name match before / alongside proximity match.** Combine fuzzy name similarity between the user-picked OSM name (e.g. "Pinehurst Course No. 2") and the GCAPI `club_name + " " + course_name` (e.g. "Pinehurst Resort No. 2") with a distance score. Reject if either signal is weak: name similarity below threshold OR distance above 1500m.

2. **Resort-aware fallback.** When the OSM name contains an ordinal / number (`No. 2`, `#4`, `Red Course`, `East`), require that token to appear in the GCAPI candidate's combined name. Rejects all sibling courses, accepts only the matching one.

3. **Multi-pick UI when truly ambiguous.** If after name+proximity scoring there are still ≥2 candidates with similar scores, present a second picker showing GCAPI candidate names so the user disambiguates. Beats binding the wrong scorecard silently.

4. **Negative cache.** Some OSM courses don't exist in GCAPI at all — record `external_course_id = NULL` for these on the shared `courses` row (already supported by schema), and don't keep retrying the API on every round-start.

**Origin:** flagged 2026-04-29 during the courses-shared schema redesign (migration 00026). The bug existed pre-redesign too — the redesign just made it more visible because the proximity check at the shared-courses level pushes more never-resolved-before courses through the GCAPI miss path.

---

## Swing-label integrity gaps (detector tuning)

Three known holes in the labeling pipeline, left open deliberately while Swing Test
Mode generates clean data. Listed together because they all corrupt or starve the
same training set.

**1. `autoAddStack` is view state, so an undo can silently mislabel.**
`ActiveRoundView.autoAddStack` is `@State` pairing each auto-added stroke with its
`swing_events` id, and it is cleared on every hole change. `undoLastStroke` looks the
stroke up there; a miss falls through to the "manual stroke" branch, which deletes
the stroke but labels nothing. So if the view is torn down, or the undo crosses a
hole boundary, a genuine false positive **stays `positive/low` forever** — recorded
as a correct detection. The failure is silent and biases the positive class.
*Fix:* persist the pairing (UserDefaults or the store) and stop clearing it on hole
change. Hole-change clearing exists only because undo doesn't cross holes anyway,
which is a UI constraint, not a reason to drop the labeling link.

**2. `positive/low` is an unverified label.**
An auto-added stroke that is never undone means only "the detector fired and nobody
objected", which includes detections the user never noticed. Nothing promotes a row
to `positive/high`, so the positive class is largely unconfirmed. Swing Test Mode
narrows this — the user is attending — but there is still no confirm gesture.

**3. `false_negative_candidates` are never reviewed.**
Every candidate's `label` is NULL. Nothing sifts them into `'true_positive_match'` /
`'noise'`, and there is no tooling to fetch and plot the per-candidate CSVs, so the
groups accumulate without feeding anything.

**Related, smaller:** `SupabaseUploader.rejectAll` (upload every detection as
`false_positive/high`, for harvesting false positives during casual wear) works but
**has no UI** — nothing writes it but its own `didSet`, so it cannot be enabled from
the app.

**Also worth remembering:** `fireSmartDetection` still returns early without a GPS
fix during round play, discarding the detection *and* its motion slice. Swing Test
Mode is exempt. That makes any swing taken before the first fix on a round an
invisible false negative — it logs `swing.fire.bail.noLocation` and nothing else.
