# v1 Punch List — "get it on the App Store"

Working doc for the final push. Every item below was verified against the code and
against live Supabase data on **2026-07-30** (84 rounds / 593 strokes / 3,377 height
cells). Findings are evidence-backed, not guesses — file:line citations and reproduced
numbers are inline so nothing has to be re-derived later.

Each item carries a **Status** and a **Decision** line. Update those as we go through
them one by one. Don't delete items when they're done — flip Status to `DONE` and
write what actually shipped.

Status legend: `OPEN` · `DECIDED` (approach agreed, not built) · `IN PROGRESS` · `DONE` · `WONTFIX`

---

## Table of contents

**Part 1 — Round-start pipeline** (how it works today, verified)
**Part 2 — Stats screen** (items S1–S8)
**Part 3 — Altitude / elevation** (items E1–E2)
**Part 4 — App Store mechanics** (items A1–A5)
**Part 5 — Recommended order**

---

# Part 1 — The round-start pipeline as it exists today

Not a to-do. This is the reference answer to "what do we actually have right now,"
so the decisions in Part 2+ have a shared basis. `docs/ROUND_START_FLOW.md` has the
exhaustive branch matrix; this is the compressed version.

## Three data sources, strict priority chain — never compared

The question was "are we scanning polygons ourselves if we can't get them from OSM,
or are we doing both and comparing?" **Answer: fallback only. Never compared.**

### Stage 1 — Identify the course
`RoundResolver.resolve()` (`GolfTracker/Services/RoundResolver.swift:170`) fires two
lookups **in parallel**:

- **Supabase `courses`** — proximity bbox over courses any user has already resolved,
  carrying cached `osm_polygons` (`fetchSharedCoursesNear`, line 269)
- **OSM / Overpass** — `way[leisure=golf_course][name](around:R)` + `relation[...]`
  (`fetchOSMCandidates`, line 217)

Merged and deduped by `osm_id` — shared wins and keeps its cached polygons, so no
re-fetch (`mergeCandidates`, line 244). Sorted by distance.

Fallback ladder when the merge is empty:
1. MapKit `.golf` POI search (`searchMapKitPOIs`, line 1074)
2. `.manual` branch → course literally named **"Unlisted course"**, tier `.none`,
   local-only, no shared-courses INSERT (`continueWith`, line 425)

### Stage 2 — Geometry (greens / tees / fairways / bunkers)
**OSM only.** Two paths:
- **Shared course hit** → `resolveExistingShared` (line 440), pulls cached
  `osm_polygons` from the DB row. No Overpass call.
- **Fresh OSM course** → `resolveAndRegisterOSM` (line 485), polygon-scoped
  `fetchCourseGeometry`, 3 m centroid dedup, then INSERT a shared `courses` row.

**Tier classification**: `.full` iff hole refs are exactly `{1..N}` — pure integers,
no dupes, contiguous. Bethpage-style umbrella mappings (5× dups) and Pinehurst
overlap fall to `.partial` and the round starts manual.

### Stage 3 — Scorecard (pars / yardages / tees)
Completely separate source: **GolfCourseAPI**, proxied through the
`golfcourse-search` Supabase Edge Function so the API key never ships in the binary
(`GolfCourseAPIService.swift`). Three fast-paths before any live call:
- cached `external_course_id` on the course row → straight to cached tees
- cross-user consensus (≥3 distinct users, ≥75% on the same id)
- skip-vote gate (≥3 users voted "course not listed") → no API call ever again

### Stage 4 — Our own polygon scan (the fallback)
```
needsBlobDetection = (osmData == nil) OR (tier != .full) OR (greens < holes)
```
Only then. And when both exist, **OSM wins outright** — `filteredGreenCandidates`
(`WatchDataStore.swift:1547`) appends OSM greens converted to `HoleDetectionBlob`
with a synthetic `greennessScore: 9_999` so they always sort above scan results.

**Delivery is server-first**: watch checks `courses.blob_detection_results`, and on a
miss sends the WC analyze request and holds the user on a round-start card that
follows the phone's reported state. The phone reports `done` only after its server
cache write lands, and the watch reads the cache on that — the WC push is a >50 KB
opportunistic file transfer that can lag minutes (this race produced an empty picker
at Wolf Hollow on 2026-07-05). A backgrounded phone queues the request and runs it on
its next foreground; see `ROUND_START_FLOW.md` Stage 4.

### Stage 5 — Simulating a course
Still present and working. `TestModeService` reads a simulated lat/lon out of
Supabase with realtime propagation; both phone and watch honor it. iPhone
`TestModeView` is the writer. This is the tool for driving a fake course from the
couch.

---

## Blob analyzer run cost

### Measured cost of running the analyzer
From `client_events` (`blob.serverCache.miss` → `blob.serverCache.uploaded`, phone, n=6):
**11-14 s, median 13 s.** Background work on `.userInitiated`, not a blocked screen.

And it is **not** per round — `startHoleDetection` checks the local disk cache first, so it's
**once per device per course**. The server cache only saves a *different* device the 13 s.

### Optimizations shipped
1. **Tiles run concurrently** (`maxConcurrentTiles = 9`). They're independent; the sequential
   loop was essentially the whole 13 s. `snapshotStandardMap` now retries on
   `MKError.loadingThrottled` with backoff instead of failing the tile, and a failed tile no
   longer sinks the run — partial coverage still places most greens. Results are merged in
   tile order so output stays deterministic.
2. **`tilePixelSize` 1600 → 1024.** 23.0M → 9.4M pixels per run; peak memory with all 9 in
   flight ~75 MB instead of ~184 MB, which is what makes 9-wide safe at all. 1.95 m/px still
   puts ~10 px across a green.
3. **Skip tiles outside the course outline.** Needs no extra trust in OSM: blobs outside the
   bounding polygons are already discarded by the existing output gate, so a non-overlapping
   tile only ever produced rejects. Bounding-box test, so partial overlap keeps the tile, and
   it never returns an empty set.

**Pixel-tuned constants made physical**, because the resolution change silently re-tuned them:
`minimumRawArea` 20 px meant 31 m² at 1600 px but would have meant 76 m² at 1024 px;
`sandScanRadius` 20 px meant 25 m but would have meant 39 m. Both are now declared in
metres and converted via `metersPerPixel`, so `tilePixelSize` can change again without
re-tuning the filter. Verified equivalent: 1024 px → 8 px area / 13 px radius = 31 m² / 25 m.

### Known-inert for now
`boundingPolygons` is **null on all 8 stored courses** — they were resolved before
`OSMCourseService` started populating it, and `resolveExistingShared` reuses the cached row
rather than re-fetching. Optimization 3 therefore does nothing until courses are re-resolved.
Correct and safe, just latent.

---

# Part 2 — Stats screen

All findings below were reproduced by running the `StatsEngine` math by hand against
the live Supabase data. The phone showed 21 rounds against the DB's 84 because nothing
downloaded history; `RealtimeSync.syncMissingRoundsWithSupabase` now pulls it on sign-in
and foreground. The mechanics are identical either way.

---

## S1 — Partial rounds poison every scoring stat  ⭐ biggest visible problem

**Status:** DONE (2026-07-30)
**Decision:** Jared — count a hole only with a couple of strokes on it; a round
scores only as a real 9 or 18; everything else is bad data and gets thrown out.

### What shipped
- `StatsEngine.minStrokesPerHole = 2` — a hole counts only with ≥2 strokes.
- `StatsEngine.scoredHoleCounts = {9, 18}` — a round enters scoring only when its
  counted holes land on a real round length.
- **Scoring bucketed by length** — `PlayerStats.scoring18` / `.scoring9`, each a new
  `ScoringStats { roundCount, avgScoreVsPar, bestScoreVsPar, avgPuttsPerRound }`.
  Flat `avgScoreVsPar` / `bestScoreVsPar` / `avgPuttsPerRound` / `totalRoundsWithPar`
  removed from `PlayerStats` (dead once bucketed).
- **Club distances deliberately exempt** — they still accumulate from every round,
  partials included. More samples, better distribution.
- `CourseStats.scoredRounds` added alongside `roundsPlayed`.
- `StatsView` — new "Scoring" section rendering 9s and 18s separately; Overview now
  shows Rounds / Scored / Putts-per-Hole.

### Bonus bug found and fixed in the same pass
`StatsEngine` resolved pars from `round.holes`, which CLAUDE.md explicitly warns
against: `Hole.round` is to-one, so older rounds' `holes` arrays **drain** as newer
rounds at the same course adopt the shared instances. Every round but the most recent
one per course had an empty holes array → `roundPar == 0` → silently skipped. `compute`
now takes `courses:` and resolves pars by `courseId`, falling back to `round.holes`
only when the course row is missing locally.

### The no-threshold win
The −6 round killed itself. Hole 7 had a single stroke, so the round has 8 counted
holes, which is neither 9 nor 18. No completeness ratio, no tuned constant. An earlier
draft used a green-reach geometric test as a per-hole filter — dropped, because it
chipped 1-2 holes out of the middle of genuine 18-hole rounds over GPS noise (a stroke
22 m from the hole marker when the cutoff was 20 m), and a 16-hole score is not a thing.

### Verified against live data (84 rounds / 593 strokes)
```
OVERVIEW    Rounds 84 · Scored 3 · Putts/Hole 1.76
SCORING     18 Holes  2 rounds   Avg +26   Best +24   Putts 34/round
             9 Holes  1 round    Avg +17   Best +17   Putts 10/round
SHORT GAME  Putts/Hole 1.76 · GIR 26%

qualifying:  2026-04-30 Hyde Park 18 holes +28
             2026-05-08 Hyde Park 18 holes +24
             2026-07-16 Hyde Park  9 holes +17
dropped:     Wolf Hollow (15), Wekiva (8), Wekiva (7), Hyde Park (8, 1-stroke hole)
```
`xcodebuild -scheme GolfTracker -destination generic/platform=iOS` → **BUILD SUCCEEDED**

### Still open, deliberately deferred
Nothing normalizes a 9-hole score against an 18-hole score — they're reported side by
side and never averaged together. That's the correct behavior and needs no further work
unless a combined handicap-style number is wanted later.

`StatsEngine.compute` (`GolfTracker/Services/StatsEngine.swift:50-59`):

```swift
let playedHoleNumbers = Set(round.strokes.map { $0.holeNumber })
let roundPar = round.holes
    .filter { playedHoleNumbers.contains($0.number) }
    .compactMap { $0.par }
    .reduce(0, +)
let nonPenaltyTotal = round.strokes.filter { !$0.isPenalty }.count
scoresVsPar.append(nonPenaltyTotal - roundPar)
```

Par is summed over **every hole with ≥1 stroke**, but strokes are only what you
actually recorded. Tee off on a par 5, hit one shot, quit → that hole scores **−4**.

**Reproduced from live data:**

| Date | Course | Holes | Par | Strokes | "Score" |
|---|---|---|---|---|---|
| 2026-04-30 | Hyde Park | 2 | 8 | 2 | **−6** |
| 2026-04-30 | Hyde Park | 2 | 8 | 3 | **−5** |
| 2026-07-05 | Wolf Hollow | 1 | 5 | 1 | **−4** |
| 2026-05-03 | Sweetwater | 2 | 9 | 5 | **−4** |
| 2026-05-08 | Hyde Park | **18** | 72 | 96 | +24 |
| 2026-04-30 | Hyde Park | **18** | 72 | 100 | +28 |

**Median holes-played across the 41 stroke-bearing rounds is 1.**
Only **2** rounds in the entire DB are true 18s. 5 rounds are ≥9 holes.

### Recommended fix
Don't try to detect "complete." Two gates, no schema change:

1. **Minimum hole count** — a round enters scoring aggregates only at ≥9 holes played.
2. **Holed-out holes only** — count a hole's par only when its last recorded stroke is
   a putt. That's the honest signal for "I finished this hole," and it also fixes the
   9-hole Hyde Park round that shows −6 because strokes stopped being recorded partway.

Everything still appears in History. It just stops feeding Overview.

Open sub-question: do we surface partial rounds anywhere in Stats (e.g. a "9-hole"
section), or are they History-only?

---

## S2 — Putts/round vs putts/hole look contradictory (they aren't)

**Status:** OPEN
**Decision:** _(pending)_

3.8 putts/round next to 1.70 putts/hole is arithmetically correct. Different
denominators:

- `avgPuttsPerRound` — `StatsEngine.swift:120-122`, divided by **round count**
  (including rounds with zero putts)
- `avgPuttsPerHole` — `StatsEngine.swift:123-125`, divided by **holes that had strokes**

3.8 ÷ 1.70 ≈ **2.2 holes per round**. Same root cause as S1. Fixing S1 fixes this
number automatically — no separate change needed, but worth re-checking after S1
lands to confirm it lands near ~30 putts/round.

---

## S3 — "Avg Shot Deviation" is structurally zero  ⭐ delete or rebuild

**Status:** DONE (2026-07-30) — stat deleted AND the real algorithm shipped
**Decision:** Jared — delete the fake stat, and implement the real swing-derived bearing.

### The stat is gone
Removed from `StatsEngine` (accumulator, tee-shot block, aggregate, and the now-orphaned
`angleDiff` helper), `PlayerStats.avgDeviationDegrees` + its CodingKey, and the `StatsView`
row. It measured **0.049° mean across 102 tee shots** because it compared bearing-to-hole
against bearing-to-hole.

### No more fabricated headings
Four sites invented a heading and were all removed:
- watch `recordStroke` — wrote bearing-to-hole for manually-added strokes
- watch `recordStrokeFromMotion` and `addLastSwingAsStroke` — fell back to bearing-to-hole
- iOS `captureAimDirection` — synthesised **bearing-to-hole + 45°** with no compass fix
- iOS `recordStroke` — defaulted to a literal `0°`

`Stroke.trajectoryHeading` is now swing-derived or nil, never invented.

### The real algorithm shipped
`Stroke.trajectoryHeading` now comes from the swing itself: the detector's swing direction
(in the algorithms package) gives each paired shape's launch bearing, and `fireSmartDetection`
records it. The detector's own pairing is the segmentation, so no phase detection was needed;
`MotionSample` was widened to carry yaw and the full gravity and user-acceleration vectors.

### Still open
- Historical Supabase rows hold fabricated headings (589/593 non-null, effectively all
  bearing-to-hole). Any `trajectory_heading` analysis must exclude pre-2026-07-30 strokes,
  or those rows get nulled — **a data-deletion call, not made.**
- The replacement stat (intended bearing vs where the ball actually went) is not built.
  The data exists now: 162 shots over 60 yds through 2026-10-25, absolute median 10° from
  the GPS line to the next stroke, no systematic offset. Tracked as S3-real.
- **Putt directionality → over/under detection.** Wanted feature, not just a validation
  chore. Once putts have a bearing, consecutive putts on a hole classify themselves with
  no distance measurement: putt N+1 on the **same** bearing as putt N means the first came
  up **short**; **opposite** bearing means it ran **past**. Across a round that's a real
  tendency stat ("you leave 70% of first putts short"), derived purely from direction.
  Blocked on validating the swing-direction algorithm for putts.
- `magAccuracy` is captured but not yet used to reject bearings from an uncalibrated compass.

---

## S4 — Club distances aren't ordered

**Status:** DONE (2026-07-30)
**Decision:** Jared — the ordering already exists as the declared type list. Use that,
everywhere, not distance.

### What shipped
`Models.swift` gained the canonical ordering, derived from `defaultClubTypes()` so there's
one declaration and no parallel list to drift:
- `ClubTypeData.canonicalOrder` — `[String]`, Drive → Putt
- `ClubTypeData.bagOrderIndex` — `Double`; unrecognized names (user-created, or a renamed
  built-in) are slotted by `averageDistance` against the canonical ladder so they land
  between their neighbors instead of at the bottom; neither-name-nor-distance sorts last
- `[ClubTypeData].inBagOrder()` — the sort

Applied at the **load sites** so every consumer inherits it and no downstream sort is
needed: `DataStore.loadClubTypes()` (iOS) and `WatchDataStore.refreshClubsCache()` (watch).
The local sort in `ClubSetEditorView:46` was deleted as dead.

### Why not averageDistance
That was the prior watch-only fix. Two failure modes: a user-created type has no distance
so it sorts to the bottom arbitrarily, and editing a club's distance silently reshuffles
the whole bag. Custom types ARE creatable (`AddClubTypeView`, free-text name), so this is
a live case, not hypothetical.

### The four sites that disagreed
| Site | Before | After |
|---|---|---|
| Watch crown (`refreshClubsCache`) | `averageDistance` desc | canonical |
| `ClubSetEditorView:46` | `averageDistance` desc | canonical (local sort deleted) |
| `ClubSetEditorView:157` selection order | **raw fetch order** | canonical |
| `StatsView:94` | **raw fetch order** | canonical |

The watch had already hit and fixed this locally — its comment even names the cause
("SwiftData fetches have no inherent ordering… without sorting, the crown was jumbled").
The fix never made it to iOS.

### Verified against the live catalog (16 types, 0 custom)
```
BEFORE  4-Hyb → 5-Wood → 5-Hyb → Pitch → 6-Iron → 7-Iron → Gap → 3-Wood →
        Drive → 5-Iron → 9-Iron → Sand → 4-Iron → 8-Iron → Putt → Lob
AFTER   Drive → 3-Wood → 5-Wood → 4-Hyb → 5-Hyb → 4-Iron → 5-Iron → 6-Iron →
        7-Iron → 8-Iron → 9-Iron → Pitch → Gap → Sand → Lob → Putt
```
iOS **BUILD SUCCEEDED** · watchOS **BUILD SUCCEEDED**

---

## S4b — Bag order is user-sortable and persisted

**Status:** DONE (2026-07-30)
**Decision:** Jared — if a custom club type can be created, it has to be placeable
wherever he wants. Make the list sortable and let that BE the canonical order.

### The bug this exposed
`ClubSetEditorView:106` already had `.onMove(perform: store.moveClubType)` — the
drag-to-reorder UI **shipped long ago**. But `DataStore.moveClubType` only did:
```swift
clubTypes.move(fromOffsets: source, toOffset: destination)
saveClubTypes()
```
There was no persisted order column, so the drag mutated the in-memory array, looked
like it worked, and evaporated on the next SwiftData fetch. Worse, S4's load-time
`inBagOrder()` would have actively stomped every drag.

### What shipped
- **`ClubTypeData.sortOrder: Int?`** — authoritative 0-based position. Optional so
  SwiftData migrates existing stores with no mapping model; nil is transient.
- **Migration `00042_club_type_sort_order.sql`** — `club_types.sort_order integer`,
  nullable. **Pushed to Supabase and verified live** (column present, 16 rows).
- **`inBagOrder()`** now sorts by `sortOrder` when set; unordered types sort *after*
  ordered ones so a freshly-synced custom type appends rather than jumping the
  arrangement. `defaultBagOrderIndex` is the fallback (was `bagOrderIndex`).
- **`renumberBagOrder()`** stamps positions from array order; returns whether anything
  changed so callers skip a pointless save + sync. Not `mutating` — `ClubTypeData` is a
  reference type.
- **`moveClubType`** renumbers the whole array, saves, and upserts every type.
- **`loadClubTypes`** backfills nil `sortOrder` from canonical position, saves, and
  pushes up. One-time; no-ops afterward.
- **`addClubType`** appends at `max(sortOrder) + 1` so a new custom type lands at the
  end and the user drags it into place.
- **`defaultClubTypes()`** self-stamps `sortOrder` from array position → fresh installs
  are ordered from first launch without waiting on the backfill.
- Carried through every read/write path: `ClubTypeDTO.sort_order`,
  `SupabaseSync.upsertClubType`, `DataStore.hydrateClubsFromRemote`,
  `WatchDataStore.upsertClubType`, `RealtimeSync.applyClubType`.

iOS **BUILD SUCCEEDED** · watchOS **BUILD SUCCEEDED** · migration pushed

### Note
`sort_order` is NULL on all 16 rows until the app runs `loadClubTypes()` once — that's
the backfill firing. Expected, not a gap.

Observed order: 5-Iron, 6-Iron, Drive, 9-Iron, 7-Iron, 8-Iron, 4-Iron…

`StatsView.swift:94` iterates `store.clubTypes` raw. `DataStore.loadClubTypes()`
(line 577) is `context.fetch(FetchDescriptor<ClubTypeData>())` — **no sort
descriptor**. `ClubTypeData` (`Models.swift`) has **no order field at all**.

The club-selection screen looks right by accident: `ClubSetEditorView.swift:46` sorts
by `averageDistance` descending, which yields Drive (245) → Putt (10).

**Fix options:**
- **Quick** — sort by `averageDistance` desc in `StatsView`, matching the editor.
  One line. Breaks if a user sets a weird custom distance.
- **Correct** — add a canonical `sortOrder` to `ClubTypeData` + a Supabase column,
  seeded from `defaultClubTypes()` order, and use it in *every* club list (Stats,
  editor, watch crown). Requires a migration and a backfill.

Note the watch already claims type ordering at `WatchDataStore.swift:656` ("follow the
type order from clubTypes (Drive → Putt)") but inherits the same unsorted source.

---

## S5 — GIR is a putt-proxy, not geometric

**Status:** OPEN
**Decision:** _(pending)_

`StatsEngine.swift:75-79`:
```swift
if let par = hole.par,
   let firstPutt = putts.min(by: { $0.strokeNumber < $1.strokeNumber }) {
    girResults.append(firstPutt.strokeNumber <= par - 1)
}
```

Two weaknesses: it only counts holes where a putt was actually recorded, and it
infers "on the green" from club choice rather than position.

**The geometric version is available.** Green polygons come from
`filteredGreenCandidates` / `OSMCourseData.greens`, and `HoleDetectionBlob.contains()`
(`Models.swift:26` region) already does point-in-polygon. Real GIR = the ball's
position after stroke `par − 2` lands inside the green polygon.

Caveat: stroke coordinates are where the *next* shot was taken from, which is a good
proxy for where the previous shot landed but carries GPS error. On-green that's ~3-5 m,
which matters at green edges.

---

## S6 — "Quick Start" and "Unlisted course" pollute By Course

**Status:** DONE (2026-07-30)
**Decision:** Jared — don't hide the placeholders, **remove the concept**. If a round starts
anywhere that isn't a course we identified, require a name. Name it once and it's that
course from then on.

### What the data showed
13 of 84 rounds were placeholders, and **every Quick Start tap made a new course row**:
```
2026-05-23  Quick Start  course_id=e0fce2a9
2026-07-16  Quick Start  course_id=55d9cbd8
2026-07-23  Quick Start  course_id=2aaf1d5a
2026-07-27  Quick Start  course_id=823c1910
2026-07-28  Quick Start  course_id=ac933a15
```
`StatsEngine` groups By Course on `courseId`, so five taps rendered as five separate
identically-titled entries. That's the duplicate Jared saw.

### What shipped
No code path creates a placeholder-named course any more. All three that did now prompt:
- `RoundResolver` `.manual` branch (was `"Unlisted course"`)
- `WatchDataStore.startManualQuickRound()` (was `"Quick Start"`)
- `DataStore.startManualQuickRound()` (was `"Quick Start"`)

New `RoundResolver.CourseNamePrompt` callback, matching the existing `coursePicker` /
`scorecardPicker` pattern so the resolver stays UI-free. On the `.manual` path it prompts,
then `insertUserNamedCourse` writes a real shared `courses` row with the user's GPS as
`center_lat`/`center_lon` (upserting on `id`, since `insertSharedCourse` conflicts on
`osm_id` which a user-named course doesn't have).

**Reuse needed no new code.** `fetchSharedCoursesNear` already matches on
`center_lat`/`center_lon` within `nearbyRadiusMeters` (4800 m), so the next round there
surfaces the course by name in the normal picker.

UI: `CourseNamePromptView` (watch, routes to dictation/scribble/keyboard) and
`IOSCourseNamePromptView` (iOS). A name is required — cancel or blank aborts the round.

### Bugs fixed along the way
- **The watch's Quick Start created no `Course` row at all** — just
  `Round(courseId: UUID(), ...)` pointing at nothing. That's the cause of the 4 orphaned
  Quick Start rounds in Supabase. It now creates and syncs a real course.
- **Cancel loop**: the resolver's nil-completion fallback called `startManualQuickRound()`,
  which now prompts — so cancelling the name prompt would immediately reopen it. Nil
  completion now starts nothing, on both platforms.
- `MultiplayerView`'s stale "Quick Start rounds can't be hosted" copy replaced. Since
  user-named courses are real `Course` rows, **multiplayer now works at them**; the check
  only fails when a course row is genuinely missing.

### Known limits
- No GPS fix at all (`startManualQuickRound`) still prompts for a name, but there's no
  coordinate to anchor it to, so it can't be proximity-matched next visit.
- Existing rows are untouched. The two `Unlisted course` rows **already carry center
  coords**, so they're re-findable and only need renaming; `Quick Start` and `H` have null
  coords. Renaming/merging them is a data edit — not done.

Both are genuine `Course` rows:
- `DataStore.startManualQuickRound()` (line 1049) creates a **brand new** course named
  `"Quick Start"` **every single tap**
- `RoundResolver.continueWith` `.manual` branch (line 425) creates `"Unlisted course"`

So `perCourseStats` treats them as venues. In the live DB there are multiple distinct
`Quick Start` and `Unlisted course` course rows.

**Options:**
- Filter them out of By Course by name (fragile but zero-risk)
- Add an `isPlaceholder` flag to `Course` and filter on that (correct)
- Reuse a single `Quick Start` course row instead of creating one per tap (fixes the
  proliferation at the source, but merges unrelated rounds under one heading)

Related: `MultiplayerView.swift:62` already treats Quick Start as a non-course
("Multiplayer requires a recognized golf course").

---

## S7 — Course rows in Stats aren't tappable, and `CourseDetailView` is orphaned

**Status:** DONE (2026-07-30)
**Decision:** Jared — option 3: build a real course-stats screen, and move the hole-detection
toggles into the hidden dev menu.

### The part that made this urgent
It wasn't "a row isn't tappable." **There was no way in the app to rename or delete a
course.** Both live in `CourseDetailView`, which nothing could reach: `CourseListView` was
its only call site and had zero call sites of its own (the Courses tab was removed from
`ContentView`). `DataStore.deleteCourse()` was only ever called from that dead screen, and
`CourseEditorView` — which IS reachable during play — only edits holes, never the name.

S6 made that a shipping problem: users now *type* course names, so a typo would be
permanent and sync everywhere. The course named `H` in the live DB (no rounds, no coords)
looks exactly like that failure.

### What shipped
`CourseDetailView` rebuilt as a stats-first screen, reached by `NavigationLink` from Stats →
By Course:
- **Overview** — rounds / scored / holes+par / last played
- **Scoring** — avg, best, worst vs par at this course
- **By Hole** — every hole with a bar showing how far over par it plays, plus avg putts.
  New `HoleStats` model + `CourseStats.holeStats`, accumulated in `StatsEngine` over
  qualifying rounds only so it stays consistent with the scoring numbers.
- **Rounds here** → existing `RoundsHistoryView(initialCourseFilter:)`
- **Layout** — the hole map, kept from the old screen
- **Manage** — Edit Course Info (rename/rating/slope) and Delete, the app's only path to either

Rows whose course row didn't sync still render, just not tappable, rather than dropping the
history.

**Dev toggles moved** to Settings → Developer (long-press the Settings title):
`runHoleDetectionAtRoundStart` and `runHoleDetectionWithTestCenter`. They drive the
satellite-blob green analyzer and were never course settings.

**`CourseListView` deleted** and deregistered from the pbxproj — genuinely redundant once
By Course is the entry point.

### Verified against live data
Hyde Park By Hole, from the 3 qualifying rounds:
```
hole 9  (par 5)  +4.0   <- toughest
hole 18 (par 4)  +3.3
hole 1  (par 4)  +2.7
hole 15 (par 4)  +0.0
```
iOS **BUILD SUCCEEDED** · watchOS **BUILD SUCCEEDED**

`StatsView.courseHistorySection` (line 110) renders a plain `VStack` — no
`NavigationLink`, no destination.

**But the destination already exists and is fully built.** `CourseDetailView.swift`
is complete. It is *unreachable dead code*:
- Nothing anywhere instantiates `CourseListView` (verified by grep — zero call sites)
- `CourseListView.swift:46` is the **only** thing that instantiates `CourseDetailView`

The Courses tab was removed from `ContentView` (now Stats | Play | History | Settings,
line 69-86) and stranded both files.

**Decision needed:** wire course rows → `CourseDetailView` (revives ~2 files of
existing work), build a purpose-made course-stats screen, or delete the dead files.
Per the repo's own editing rule, dead code should not just sit there.

---

## S8 — What the "Rounds" count means

**Status:** DONE (2026-07-31)
**Decision:** Jared — History shows **every** round so partials can be found and deleted.
The Overview count therefore stays "all rounds," matching what's browsable; `Scored` beside
it carries the S1 rule. No change to the counter.

### The bug this surfaced
`deleteRound` removed the round from the published `rounds` array and synced the delete to
Supabase, but **never called `context.delete`** — `DataStore` never called it for anything.
`loadRounds()` re-fetches the whole context, so a deleted round came back on the next launch
unless the Supabase delete round-tripped through Realtime's `applyRound(.delete)`. Deleting
offline, or missing that event, resurrected it. Now deleted from SwiftData directly; the
Realtime echo is belt-and-braces. Cascade takes strokes and targets, `Round.holes` stays
`.nullify` so the course keeps its holes.

### What shipped
- **Swipe-to-delete in History**, with a confirmation naming the course and date. Deleting
  previously meant opening each round's detail screen first — unusable against 38 abandoned
  starts.
- **Holes-played on each row**, so a partial is obvious without opening it. A round with no
  strokes reads "No shots recorded" in orange.

Verified: 79 rounds on record, 41 with any stroke, 3 qualifying for scoring.

Verified: 2026-07-05 and 2026-07-06, all `location_test_mode_enabled = false` except
one. One legitimate **15-hole / 92-stroke** round, plus nine short restarts. Consistent
with the blob-delivery race being debugged that weekend.

Fixing S1 makes this display correctly on its own (9 of 10 drop out of scoring). The
open question is whether "10 rounds" should keep counting *attempts*, or count only
rounds that qualify for stats. Two different numbers, both defensible.

---

# Part 3 — Altitude / elevation

The pipeline is further along than "needs setting up." **It's live and accumulating.**

Live data as of 2026-07-30:
```
hole_height_cells:        3,377 cells across 4 courses
round_altitude_readings:  6,355 rows

Wolf Hollow      1,552 cells
Hyde Park          873 cells
Wekiva             944 cells  ← split across two key namespaces, see E1
Unlisted course      8 cells
```

Confirmed behavior: no cells for a course → no readout, and it degrades **silently**
rather than displaying something wrong. That's the correct fallback and it already
works.

---

## E1 — `hole_key` casing split

**Status:** DONE (2026-07-30), with a data loss — see below
**Decision:** Jared — normalize it; and after the incident, let Wekiva's map reseed
naturally rather than reconstructing it.

### Correction to the original diagnosis
The first read of this was wrong. Wekiva was NOT "running on half its data with the newer
half invisible." The two casings held **byte-for-byte identical** cells — same 472
(hole, cell) keys, zero differing values. The uppercase half the client reads was complete,
so nothing was missing. What existed was 472 redundant rows plus a latent hazard: because
`upsert_hole_height_cells` merges on `hole_key`, any future write in the other casing would
accumulate into a namespace the client never reads, and *that* would have lost real data.

### What shipped (migration 00043)
- `ElevationFoldIn.holeKey` now lowercases — Swift's `uuidString` is uppercase, Postgres
  renders uuid lowercase, and letting both in is what split the map.
- Every existing key lowercased.
- **Structural guard**: `upsert_hole_height_cells` lowercases `p_hole_key` internally, and
  a CHECK enforces `hole_key = lower(hole_key)`. Since direct DML is revoked from
  `authenticated`, the RPC is the only write path, so this is a true invariant rather than
  a convention. Verified live: an uppercase key sent to the RPC lands stored as lowercase.

### ⚠️ Data loss during this migration
The first version of the cleanup `DELETE` destroyed **all 944 Wekiva rows** instead of the
472 duplicates. Operator precedence: `AND` binds tighter than `OR`, so the guard evaluated
as `(A AND B) OR C`, and the two branches matched **opposite members of each pair** —
branch one deleted the uppercase row, branch two deleted the newer (lowercase) row. Both
rows satisfied a branch, so both went.

Recoverable in principle and deliberately not recovered: `hole_height_cells` is derived
from `round_altitude_readings`, which was untouched (6,354 rows; Wekiva's 510 readings
across holes 1-5 all present). Reconstructing would mean reimplementing the offset-solve
and 3 m bucketing outside Swift, where a subtle error writes *wrong* elevations into a
shared table. Wekiva's map reseeds on the next round played there. Wolf Hollow (1,552
cells) and Hyde Park (873 cells) were never touched.

The migration file has been corrected to a single-predicate `EXISTS` form so a replay on a
fresh database does the right thing. **Rule going forward: run a migration's DELETE as a
SELECT and check the row count before converting it.**

iOS **BUILD SUCCEEDED** · watchOS **BUILD SUCCEEDED**

```
D133B094-045A-49FE-B4E5-ACD60614C7C1:*   472 cells   updated 2026-05-31
d133b094-045a-49fe-b4e5-acd60614c7c1:*   472 cells   updated 2026-06-12
```

Same course (Wekiva Golf Club), two disjoint key namespaces.

`ElevationFoldIn.holeKey` (`ElevationFoldIn.swift:60`) is
`"\(courseId.uuidString):\(holeNumber)"`, and Swift's `uuidString` is **always
uppercase**. So the lowercase rows were **not written by the app** — timestamps point
at a re-solve/backfill run on 2026-06-12 that took UUIDs from the DB (Postgres emits
lowercase) and wrote them back verbatim.

**Consequence:** `HoleHeightCellCache.loadForCourse` (`HoleHeightCellCache.swift:33`)
builds its `in("hole_key", values: keys)` from `uuidString`, so it only ever sees the
uppercase half. Wekiva is running on half its accumulated elevation data, and the
newer half is invisible.

**Fix:** normalize `holeKey` to a single casing (lowercase is the safer target since
Postgres and any future SQL-side job will emit it), migrate existing rows, and merge
the two halves for Wekiva via the same weighted-merge the `upsert_hole_height_cells`
RPC already implements. Also worth adding a case-insensitive guard so a future
SQL-side backfill can't re-split it.

---

## E2 — Altitude for v1: leave on, or hide?

**Status:** OPEN
**Decision:** _(pending)_

Current state, all shipped and working:
- Live "↑3 / ↓7 ft to green" readout (`ElevationReadout`, time-decayed calibration,
  5×5 weighted cell neighborhood)
- Club-trajectory-aware plays-like yardage (`PlaysLike`, TrackMan landing angles per
  club type)
- Watch: big yardage number tap-toggles measured ↔ plays-like, signaled by color
- iOS: `PlaysLikeStack` beside the big yardage
- Elevation-aware club prediction
- Round-end durable fold-in with retry-on-foreground

It already self-hides when there's no solution (new course, no history, test mode,
putter). **The fallback you described is the behavior that's actually implemented.**

Given that, the v1 question is narrow: is the readout *accurate enough* on a
first-visit course to leave enabled by default, or does it need a confidence gate
(e.g. minimum `n_samples` in the target neighborhood) before it displays? Fixing E1
first will change the answer for Wekiva.

---

# Part 4 — App Store mechanics

**`docs/APP_STORE.md` is the doc for this** — submission state, the build and upload
recipe, the screenshot method and its traps, and Apple's requirements. The items below
stay as the record of what was decided and done; current status lives in that doc.

---

## A1 — Version bump 0.9.0 → 1.0.0

**Status:** DONE (2026-07-31) — `1.0.0 (7)` at the time, exceeding the last upload (6).
Builds have moved on since; `docs/APP_STORE.md` carries the current number and the bump
procedure.

---

## A2 — Screenshots

**Status:** IN PROGRESS (2026-09-14)
**Decision:** Jared: shots come from the simulators with staged data; stats shots approved;
in-round shots on par 5s with water, targets on the far edge of the water, strokes with
their trail; no near-green shots (the on-green readout doesn't show the app off).

18 iPhone and 18 Apple Watch in-round shots are staged and waiting on Jared's pick, plus
the approved stats screens. The method, the traps and the tooling
(`StrokeSaverAlgorithms/tools/screenshots/`) are in `docs/APP_STORE.md`; the staged rounds stay in the database
until the set is approved.

---

## A3 — Listing copy, category, age rating

**Status:** OPEN
**Decision:** _(pending)_

- Description + keywords drafted in `docs/LISTING.md` — needs a read-through
- Category: Sports (primary), Health & Fitness (secondary)
- Age rating questionnaire → will land 4+
- Review notes (optional, speeds review)
- Marketing URL (optional, can reuse Support URL)

Copy rule for anything written in Jared's voice: no em-dashes, no connector hyphens
(use parentheses), and no hedging or "known limitations" language in shipped
user-facing text.

---

## A4 — Release-configuration smoke test

**Status:** DONE (build half) — iOS and watchOS both **Release BUILD SUCCEEDED**, no
errors, every warning pre-existing (Swift 6 concurrency prep, one iOS 17
`UITraitCollection(traitsFrom:)` deprecation, an intentional unused result on
`UnifiedDetector.process`). None block submission.

**Still owed:** install the Release build on device and play a round, checking that the
`#if DEBUG`-gated `dprint` calls leave no console spam and take no load-bearing logging
with them. That half needs hardware.

---

## A5 — Dead code sweep before submission

**Status:** DONE (2026-07-31)
**Decision:** Jared — delete the superseded detection modes provided `unifDetect` doesn't
lose anything. **Checked first: they were already gone.**

### The detection modes were a stale doc claim
`DetectionMode` has exactly two cases, `.off` and `.unifDetect`. Zero references to
`naiveDetect` / `smartDetect` / `unifiedDetect` anywhere, and `FullSwingDetector.swift`,
`PartialDetector.swift`, `PuttDetector.swift` were deleted long ago. Nothing to remove —
CLAUDE.md's "older modes still in codebase" line was simply out of date. Worth having
verified rather than deleting on the strength of the doc.

### What the sweep actually found — a live bug, not dead weight
`HomeView` was dead (referenced only by its own `#Preview`), **but
`LocationPermissionBanner` was mounted only on it.** So the iOS location-denied UX was
unreachable: deny location and you got no guidance at all, since `startRoundAtCurrentLocation`
falls straight through to `startManualQuickRound` and its name prompt. `docs/APP_STORE.md`
had this ticked off as done.

Apple tests permission-denied states, so this was a plausible rejection on its own.

**Fixed:** banner re-homed to `PlayTabView`'s start screen — the screen that actually needs
location — and `HomeView.swift` deleted and deregistered from the pbxproj.

### Everything else checked out live
`MotionParametersView`, `GreenFiltersView`, `TestModeView` (Settings → Developer),
`ActiveRoundConfiguredView`, `ViewSettingsView`, `AddClubTypeView` all have real call sites.
`CourseListView` was already removed in S7.

Known dead as of this audit:
- `CourseListView.swift` — zero call sites
- `CourseDetailView.swift` — only referenced by the above (see S7; may get revived
  instead of deleted)

---

# Part 5 — Recommended order

Rationale: the Stats screen is what a person clicks first, and **"−9 best score" next
to "21 rounds"** is the single thing that makes the app look broken. S1 + S4 + S3 is a
small, contained change set that removes every obviously-wrong number.

| # | Items | Why here |
|---|---|---|
| 1 | **S1, S2, S4, S3** | Kills every visibly-wrong number. Contained, no schema change (S4 quick path). |
| 2 | **S6, S7** | Cleans up By Course and revives or removes orphaned screens. |
| 3 | **E1** | Small, and it recovers real data that's currently invisible. |
| 4 | **A1–A5** | Submission mechanics. Nothing here is hard, it's just a checklist. |
| 5 | **S3 (real version), S5, E2** | Post-launch. The swing-derived deviation stat is the most interesting thing in the app but it's genuine algorithm work with a validation loop. |

---

# Part 6 — Round and hole sync (found 2026-09-14)

Found while staging App Store screenshots on the simulators (Disney's Palm, round
`a2f8a4ab` started on the phone, then `80780c52` started on the watch). All three are
reproduced, not inferred, unless marked.

## R1 — Starting a second phone round at a course crashes the phone

**Status:** DONE (2026-09-14, `52e358f`) · **Decision:** Jared: fix it; rounds get their
own holes on the phone, as on the watch and in `round_holes`.

**What shipped:** `startRound(for:)` builds copies (`Hole.roundCopy`, ids from
`Hole.roundHoleId(roundId:number:)` so every device writes the same row); stores that
still shared are split at launch on both platforms and their `round_holes` rewritten.
Verified on the simulators: a second phone-started Palm round started without a crash,
and the launch split left no course hole attached to a round on either device.

`DataStore.startRound(for:)` builds `Round(holes: course.holes)`. `Hole.round` is
to-one, so once one phone round at a course holds those holes, the next one's insert
in `saveRounds()` (DataStore.swift:498, from :982) dies on
`SwiftData/ModelContext.swift:935: Fatal error: This relationship already has a value
but it's not the target`. Reproduced twice from Start Round → Palm → Course not listed;
the local store showed all 18 in-use Palm holes pointing at the 18:58 round.

Only the phone shares: the watch's `performStartRound` builds a fresh snapshot of
holes per round, and the server's `round_holes` rows have their own ids per round.
Proposed fix: the phone snapshots too. What changes: a correction to a course hole no
longer reaches past rounds on the phone — which is already the case for every
watch-started round and on the server, and which the shared design never delivered
anyway, because each new round drains the holes out of the previous one.

## R2 — A course can end up with every hole twice on the phone, and then the phone and watch disagree about which hole you're on

**Status:** DONE (2026-09-14, `52e358f`, `fcb7484`) · **Decision:** Jared: the phone and
watch must never be able to disagree; state lives on the server.

**What shipped:** the phone fetches a course the server already has instead of rebuilding
it (`courseForRound`); a server hole row replaces any other local hole with its number;
doubled courses are repaired at launch. Which hole a round is on is now a hole number
(`rounds.current_hole_number`, migration 00051, with a trigger keeping the legacy index in
step for older builds), resolved against the round's own holes. Verified: no doubled
course on either device after launch; the trigger mapped number 5 → index 4 and index 10 →
number 11 on the live table.

The phone's Palm course has 36 hole rows, two per number: one with an id the phone
generated, one with the server's `holes` id. Every other course on the simulator has
one per number. `HolePlayView.holesSorted` indexes `currentCourse.holes`, so on the
phone index 13 is hole 7 and hole 14 is index 26 — while the watch's index 13 is hole
14. Both devices write `rounds.current_hole_index`, so each one moves the other to the
wrong hole (the watch reached 14; the phone showed 7; the phone's own navigation
then wrote 26).

Cause: `startRound(from:selectedTeeId:)` creates a local `Course` with freshly
generated `Hole` ids when the course is not in the local store, even when the server
already has it. `SupabaseSync.upsertHole` upserts on `id`, so the server keeps its own
rows for those numbers, and those rows arrive later through reconcile / Realtime as
new holes. (Unverified: whether the phone's rejected hole upserts then sit in the
`SupabaseSync` retry queue indefinitely — `holes` is unique on `(course_id, number)`.)

## R3 — Every hole change sends 19 concurrent writes, and opening Play overwrites the hole

**Status:** DONE (2026-09-14, `fcb7484`, `559b36d`) · **Decision:** Jared: fix it.

**What shipped:** a hole change is one PATCH (`updateCurrentHole`); `upsertRound` writes
the round row only; each device's writes go through one ordered on-disk queue (merging
repeats, dropping writes the server refuses outright); an incoming row never overwrites
a local write still waiting for confirmation; opening Play writes nothing. Verified:
three fast Previous taps on the phone left server, phone and watch on the same hole
(0.3 s, 0.3 s, 0.8 s), and opening Play left the round's `updated_at` unchanged.

`updateCurrentHoleIndex` (both platforms) calls `SupabaseSync.upsertRound`, which
rewrites the round and all 18 `round_holes` rows; `attempt` fires each write as its
own `Task`, and a failed one is replayed later. One session of hole changes delivered
738 `round_holes` events to the phone, which then replayed hole changes about 3 s
apart. Concurrent writes can commit out of order, and a late retry can overwrite a
newer hole. Separately, `HolePlayView.onAppear` writes the phone's local index back
to the round on every appearance, so a phone that re-enters Play with a stale hole
overwrites the watch's.

Proposed fix: a hole change writes only the `rounds` row, writes to one row are
serialized, and `onAppear` reads the round instead of writing it.

## R4 — In a solo round the watch never saw the phone's changes until it relaunched

**Status:** DONE (2026-09-14, `559b36d`, `9508752`)

watchOS opens Realtime only for multiplayer, so a solo watch round had no live link: a
hole change, stroke, target or deletion made on the phone reached the watch only at its
next launch, and targets and deletions not even then (catch-up pulled neither). The phone
now forwards every round row it receives (`WatchConnectivityManager.relayRow`), its
Realtime stays up when Play closes, and catch-up pulls targets and trims each recent
round to exactly the server's rows. Verified: a server-side change reached the watch
0.6 s after the phone; a new target 1.5 s; a deleted stroke 1.0 s; a hole change made on
the watch reached server and phone within the same poll.

## R5 — Starting or ending a round sends the phone to the Stats tab

**Status:** DONE (2026-09-14)

Seen twice on 2026-09-14: once when a round ended elsewhere (Play closing), once when a
round started from Play. The app was not signed out (the auth log has no entries at
either moment) and did not relaunch (same process). `ContentView.mainTabs` had no
`selection` binding, so any rebuild of the tab view landed on the first tab.

**What shipped:** the tab view is bound to a `@SceneStorage` selection with a tag per tab,
so a rebuild keeps the tab. Verified on the same repro before and after: with the phone
on Play in a round, ending the round on the server moved it to Stats within 3 s on the
old build; on the fixed build it stays on Play and shows the start screen. Starting a
round from Play on the fixed build lands on the round's hole screen.

---

**Created:** 2026-07-30
**Last updated:** 2026-09-14
