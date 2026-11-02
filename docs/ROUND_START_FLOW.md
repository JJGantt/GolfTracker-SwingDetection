# Round-Start Flow

The matrix of decisions a round goes through from "user taps Start" to
"user is on the placement view / playing hole 1." Every branch here is
real — courses in OSM range from "fully mapped 18-hole+greens+tees+pars"
to "name only, zero geometry," and GCAPI scorecard coverage is similarly
patchy. We have to handle all combinations.

This doc is the source of truth for the flow. When you change any branch,
update this doc IN THE SAME COMMIT so the matrix stays accurate.

---

## Inputs at decision time

| Input | Source | Possible values |
|---|---|---|
| OSM coverage | `OSMCourseService.fetchCourseGeometry` → `OSMCourseData.tier` | `.full` (refs 1..N clean) / `.partial` (some holes/greens, refs messy) / `.none` (no greens at all) |
| Per-hole pars in OSM | `OSMHole.par` field | nil / Int per hole |
| GCAPI scorecard | `RoundResolver.searchScorecard` → ranked candidates | none / one / multiple |
| GCAPI tee data | `GCAPICourse.tees` | empty (stub row) / populated (per-tee + per-hole pars/yards) |
| Cross-user consensus on scorecard | `course_scorecard_picks` | <3 picks / consensus reached |
| Cross-user "Course not listed" votes | `course_scorecard_skips` | <3 / ≥3 (skip API entirely) |
| Per-user prior pick on this course | `course_hole_picks` (this user, this course) | absent / present |
| Cross-user blob-pick consensus | `course_hole_picks` (any user) | <3/<75% / consensus |
| Server-cached blob detection | `courses.blob_detection_results` | absent / present |

---

## Stage 1 — Course identification (RoundResolver.resolve)

```
Always run BOTH in parallel:
  shared-courses lookup (Supabase courses table, proximity bbox)
  OSM lookup (Overpass leisure=golf_course near GPS)

Merge: dedupe by osm_id (shared wins, keeps cached osm_polygons).
Group OSM matches: cluster within 500m + shared stripped tokens
  → one canonical entry per real course (siblings carry extra polygons
  for the second-pass query).

→ presentCandidates(merged):
   • count == 0           → MapKit POI search; if still empty, .failed
   • count == 1           → still show picker (per spec — no silent pick)
   • count > 1            → coursePicker UI
```

User picks → `continueWith(candidate)`.

---

## Stage 2 — Course resolution

Three branches based on candidate source:

### 2a. Shared course (already in DB)
`resolveExistingShared` — pulls cached `osm_polygons` from DB row.
No Overpass call. Then → Stage 3.

### 2b. Fresh OSM course
`resolveAndRegisterOSM` — `osm.fetchCourseGeometry` (uses canonical +
sibling polygons unioned), 3m centroid dedup on sub-features. INSERTs
new shared `courses` row. Then → Stage 3.

### 2c. MapKit POI (fallback when OSM had nothing)
Tier-none, no polygon data, skips Stage 3 scorecard search proximity
filter. Then → Stage 4 with `osmData = nil`.

---

## Stage 3 — Scorecard (GCAPI)

Decision tree in `resolveScorecard` → `runScorecardSearchWithPicker`:

```
1. Cache fast-path
   IF this course's row already has external_course_id in DB
      → fetch cached tees (no API call)
      → return stub course → Stage 4
      (no picker — we already know which scorecard)

2. Consensus fast-path
   IF >=3 distinct users + >=75% picked the same external_course_id
      → silent-pick the consensus → Stage 4
      (no picker — community has converged)

3. Skip-vote gate
   IF >=3 distinct users picked "Course not listed"
      → no API call, scorecardCourse = nil → Stage 4
      (no picker — community has converged on no scorecard)

4. Search + picker (the "fresh course" path)
   stripCourseName(courseName) → GCAPI search
   For each candidate:
     • Resolve a coord — real API lat/lon if shipped, else geocoded
       city/state centroid (geocoder refuses state-only).
     • Coord within 25km of OSM coords  → inRange
     • No coord at all                  → noLocation
     • Coord present but >25km          → DROPPED (filtered out)
   Stub rows (no tee data) STAY visible — at multi-course resorts a
   sibling entry may have full data while the user's actual course is a
   stub, and silently substituting would be worse than showing both with
   the user picking. Picker labels stubs with "(no scorecard data)".

   Sort: inRange (by distance ascending) → noLocation. Always show picker
   even if one result (no silent pick).

   Why 25km and not tighter: the API publishes one coord per CLUB, not per
   COURSE. Multi-course resorts collapse to a single point — Citrus Hills
   FL stamps all four of its courses at the Terra Vista club centroid,
   even though Brentwood Farms is 3.8km west on its own property. A
   1.5km gate dropped the right scorecard. 25km catches the resort case
   while the stripped name + same-region constraint keeps cross-state
   collisions out (Sweetwater FL vs Sweetwater TX, >1500km).

   User picks scorecard → recordScorecardPick (await before completion)
   User picks "Course not listed" → recordScorecardSkip (await before completion)
```

---

## Stage 4 — Round creation (WatchDataStore.startRound → performStartRound)

```
needsHydration = (tier != .full) OR (greens count < holes count)

IF needsHydration:
   Task: fetch canonicalHolePlacements (course_hole_picks)
   then MainActor.run { performStartRound(canonicalPicks: <fetched>) }
ELSE:
   performStartRound(canonicalPicks: [:]) directly
```

`performStartRound` builds the Round + Holes:

```
IF tier == .full AND osmData has greens:
   Build all holes from OSM. Coordinates + pars + tee_id all set
   from OSM hole data. No HolePlacementView for any hole.

ELSE IF canonicalPicks[1] exists:
   Build hole 1 with the canonical pick's coord + par. No placement
   view for hole 1.

ELSE:
   Build single placeholder Hole(number: 1, teeId: ...). HolePlacementView
   appears immediately.
```

Then:
```
ALWAYS:
  upsertRound to Supabase
  Hydrate per-tee yardages + pars from cached_holes (when selectedTeeId set)

needsBlobDetection = (osmData == nil) OR (tier != .full) OR (greens < holes)

IF needsBlobDetection:
   round.holeDetectionEnabled = true
   Task: fetchServerCachedBlobs
       cache hit  → store in holeDetectionDataByCourse
       cache miss → WC sendHoleDetectionRequest to iPhone
                    round-start card (BlobRequestCard) holds the user,
                    showing the phone's reported state, until Continue
                    or the results land
                    iPhone on screen → runs now; backgrounded → queues
                    and runs on its next foreground
                    iPhone reports queued / running / done / failed;
                    on done the watch reads the server cache
                    results arriving after Continue still apply
```

The card exists because the phone is the only place the analyzer can run and
it usually receives the request in the background, where the analyzer's MapKit
snapshots do not complete (the run dies with no error and the course gets no
blobs). `sent`/`running` show a spinner;
`unreachable` (the WC send failed or the phone was not reachable) and `queued`
(the phone has it but its app is not open) show the unreachable message.
Resuming a round whose blobs are still missing re-sends the request once per
app session, without the card.

---

## Stage 5 — Per-hole placement (HolePlacementView)

Appears when current hole's coordinate is nil (`needsFlagPlacement`).
Skipped automatically when:
- Stage 4 created the hole with a coord (Tier-1 OSM OR canonical pick hit)

When it does appear:
```
Show map + blob overlays from filteredGreenCandidates (OSM greens +
blob detection results, filtered by holeFilterSettings).

Under them, the round so far (`RoundTrail`): the whole walked path
(pathSamples, decimated to ≤300 points), every hole's shot connector
and shot dots, each placed flag with its hole number, and each swing's
launch-bearing ray. Over them, the user dot with a compass wedge —
the only screen that runs the compass (`LocationManager.beginCompass`
on appear, `endCompass` on disappear).

Tap behavior:
  isManualPlacement OR no candidates → drop pin at tap location
  ELSE → snap to nearest blob within 50m (selectedGreenBlobId set)

knownPar:
  IF teeHolePars[hole.number] is set (from GCAPI tee data) AND not
  editing → auto-save with that par on tap; skip par picker.
  ELSE → par picker (3/4/5).

Save:
  upsertCourseHolePick (this user's blob pick stored cross-round)
  store.updateHole — writes coord + par to round_holes
```

---

## Stage 6 — addNextHole (during play)

```
nextHoleNumber = round.holes.count + 1
Consult canonicalHolePlacementsByCourse[courseId]?[nextHoleNumber]:
  Hit → create Hole with coord + par from canonical
  Miss → create Hole(number: nextHoleNumber) with no coord
         → HolePlacementView appears
```

---

## Real-world course matrix (current as of testing)

| Course | OSM tier | OSM pars | GCAPI | Result |
|---|---|---|---|---|
| Hyde Park (Jacksonville FL) | full | yes | full scorecard | Tier-1, no picker after first round, all holes pre-placed |
| Wekiva (Longwood FL) | partial (relation present, no holes) | n/a | full scorecard | Tier-3, scorecard tees, blob detection per hole, canonical picks accumulate |
| Sweetwater (Apopka FL) | partial (3 hole entries refs 1/1/2, 2 greens) | one hole has par | name-only stub, no tees | Tier-3, no scorecard, blob detection per hole, manual par picker |
| MetroWest (Orlando FL) | partial | unknown | full scorecard | Tier-3 + scorecard, picker → tee picker → blob detection per hole |
| {recently-added full-OSM course} | full | yes | none | Tier-1, no scorecard picker, all holes pre-placed from OSM, "skip scorecard" message must NOT promise manual entry |

---

## Cross-user voting tables (current state)

| Table | Threshold | Purpose |
|---|---|---|
| `course_hole_picks` | ≥3 distinct users + ≥75% on same blob_id per hole_number | Canonical green polygon for a hole; skips placement view on subsequent rounds |
| `course_scorecard_picks` | ≥3 + ≥75% on same external_course_id | Canonical scorecard; skips picker on subsequent rounds |
| `course_scorecard_skips` | ≥3 distinct users | Course confirmed not in GCAPI; skips API call on subsequent rounds |

---

## Logged events for tracing

Every stage emits events to `client_events`. Useful queries during testing:

```sql
-- Full flow for a recent round attempt
SELECT to_char(occurred_at,'HH24:MI:SS'), device, event, detail
FROM client_events
WHERE user_id='<uid>' AND occurred_at > now() - interval '15 min'
  AND (event LIKE 'resolver%' OR event LIKE 'osm%' OR event LIKE 'gcapi%'
    OR event LIKE 'blob%' OR event LIKE 'canonicalP%' OR event LIKE 'priorH%'
    OR event LIKE 'greenHydrate%' OR event LIKE 'HolePlacement%'
    OR event LIKE 'addNextHole%' OR event LIKE 'updateHole%'
    OR event = 'watch.build.launched')
ORDER BY occurred_at;
```

Key events:
- Stage 1: `resolver.sharedQuery`, `resolver.osmQuery`, `resolver.merged`
- Stage 2: `resolver.sharedCourseInserted`, `osm.fetchGeometry.ok`
- Stage 3: `resolver.scorecard.fastPathHit`, `resolver.scorecard.consensusHit`,
  `resolver.scorecard.skipVoteGate`, `resolver.scorecard.searchStart/Ranked`,
  `resolver.scorecard.pickRecorded`, `resolver.scorecard.skipRecorded`
- Stage 4: `canonicalPlacements.fetched`, `blob.serverCache.hit/miss/uploaded`,
  `blob.request*` (`.undeliverable` on the watch, `.queued` on the phone),
  `blob.phoneStatus`, `blob.prompt.continued`, and phone-side
  `blob.analyzer.started/succeeded/failed/noCenter/courseMissing/backgroundExpired`
  — `failed` carries every tile's error
- Stage 5: `HolePlacementView.onAppear`, `HolePlacementView.save.tapped`,
  `updateHole.start/saved`
- Stage 6: `addNextHole.start/saved/canonicalHydrated`
