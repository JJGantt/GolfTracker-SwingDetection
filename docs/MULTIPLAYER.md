# Multiplayer Rounds + Scorecard + Tee Data — Design Spec

**Status:** Implemented (2026-04-28). All seven steps shipped: GolfCourseAPI integration → solo scorecard → playgroups schema/service → MultiplayerView → live dots + other-player strokes → walkie-talkie → multi-player scorecard → 6h auto-close. **Deviations from spec:**
- Walkie-talkie audio sends via Realtime **binary broadcast** (no persistence) instead of the originally-considered Storage+DB-row path. Migrations `00016` created the table+bucket, `00017` dropped them. Empty bucket left in place since SQL can't delete buckets.

**Post-implementation polish (same day):** SIWA→profiles upsert wired, Settings name editor added, `PlaygroupChannel.members` now subscribed to live postgres-changes (mid-round joins/leaves work), scorecard auto-refreshes via `.onChange(playgroup.otherStrokes)`, audio session deactivates after PTT.

**Outstanding non-design items:** on-device verification with two physical devices in a real playgroup; iOS background-receive for walkie-talkie (currently foreground-only on phone, watch is always-on via workout session).

## Overview

Two or more golfers playing the same physical round at the same course can share a live session in the app. Each player still owns their own round (their strokes, their score, their stats); the multiplayer feature is purely about **shared visibility** during the session — seeing each other's positions and strokes on the map, comparing scores in real time on a shared scorecard.

History persists. After a shared round ends, the session record stays in the DB so users can browse "rounds played with Mike" and compare past shared rounds.

## Three actions

A new "Multiplayer" view in Settings (accessible on both watch and phone) exposes:

- **Host Round** — creates a new playgroup, marks the host as discoverable to nearby app users. The host's own round starts immediately on the chosen course (uses the existing round-resolver flow).
- **Join Round** — shows a list of nearby playgroups (within tight GPS proximity, see below). Each entry shows the host's first name + current member count. Tap to send a join request.
- **Pending requests** (host-only, only visible when the user is hosting) — list of users requesting to join, with `[Accept]` / `[Decline]` per row.

Solo rounds (the existing "Play Round" / "New Round" flow) remain unchanged and are **not** discoverable.

## Discovery model

- The host of a playgroup is exposed by **first name only** to other app users within tight GPS proximity (target: 50–100m of the host's GPS at host-time).
- The proximity check happens server-side. Other users' raw GPS coordinates are never exposed; the server only returns "this playgroup is near you" or not.
- Once a user is **accepted into** a playgroup, full live position + stroke data flows to the other members for the duration of the round.

### First-name capture

Sign In With Apple provides first/last name only on the very first sign-in, and only if the user opts to share their real name (they can choose "Hide My Name" which gives us a relay email and no name).

- Capture the SIWA-provided first name on initial sign-in into a new `profiles` table keyed to `auth.users.id`.
- Fallback when SIWA name isn't shared: prompt for a display name during onboarding ("What should other players see?"), default to "Player" or first 3 chars of email.
- Display name shown to other players in the multiplayer picker is just the first name (or chosen display name).

## Join flow

1. User A taps **Host Round** → playgroup row created with `status='open'`, host_id = User A → User A's round starts as normal.
2. User B is at the same course, taps **Join Round** → server returns nearby playgroups in `status='open'` within proximity → list shows "Jared's round (1 player)".
3. User B taps the entry → join request created (or sent via Realtime to host).
4. User A's app shows the pending request in the multiplayer view (in-app only — no APNs / system notifications).
5. User A taps **Accept** → User B added to `playgroup_members`, User B's app gets the confirmation and User B's round starts in the shared playgroup context.
6. Repeat for additional players. **Only the original host can accept join requests** — single point of control, no invite-chain creep.

If User A declines, User B sees "request declined" and can try a different host.

## Privacy boundaries

- **Pre-join:** other users see only `{ first_name, course_name, member_count }` of a hosted playgroup. No GPS coords, no user IDs, no email, no scores.
- **Post-join (during the shared round):** members can see each other's GPS positions on the map, recorded strokes on the map, and live scores on the shared scorecard.
- **Post-round:** persisted playgroup record retains member round IDs for history. Cross-user round visibility ENDS when the playgroup transitions out of open status — but historical playgroup membership stays for "rounds played with X" history. Any future viewing of those past shared rounds shows the data as it was; we don't grant ongoing read access to each other's currently-live data.

## Visual design on the map

- **Color per player.** Assigned at join time (probably from a fixed small palette: blue, red, green, orange, purple, teal). Same color for the player throughout the shared round AND on the scorecard, so the user can map a dot on the map to a row on the scorecard at a glance.
- **Player position marker:** full saturation, with the player's first-name initial or label.
- **Player stroke markers:** lighter / fainter version of the same color (less saturation, smaller dot) to distinguish them from active position.
- **Faint connecting line** between consecutive stroke markers within a hole, so you can see shot trajectory and length at a glance.
- Apply the same line-through-shots pattern to the **single-player** map too (we don't currently render this; worth adding while we're at it).
- Realistic player count is 2–4. Cap at 6 for color palette safety.

## Scorecard

Standard golf scorecard layout (built single-player first, then extended for multi-row):
- Holes 1–9 across the top
- Holes 10–18 across the bottom
- Par row above the player row(s)
- One row per player: stroke counts per hole + 9-hole subtotals + 18-hole total
- Each player's row tinted with their assigned color (matches the map)

## Lifecycle

A playgroup transitions through:
- `open` — created by host, accepting join requests, members can join
- `closed` — round in progress, no new join requests accepted (post-end-of-round, post-time-cleanup, or via host-explicit end)
- (no separate "ended" — closed covers it; round completion just sets `ended_at`)

Auto-close to new joiners happens when ANY of:
- Host completes hole 18
- 6 hours elapsed since `started_at` (covers any reasonable round + lingering)
- Host taps an explicit "End round / stop accepting joiners" button

The playgroup row and all member round_ids persist forever — the close transition only changes joinability, not data retention.

If the host quits the app or app crashes mid-round, the same time-based + hole-18 cleanup applies — no special handling required.

## Schema

Two new tables. Migration `00011_playgroups.sql`.

```sql
create table playgroups (
    id uuid primary key default gen_random_uuid(),
    host_id uuid not null references auth.users(id) on delete cascade,
    course_id uuid references courses(id) on delete set null,
    course_name text not null,
    started_at timestamptz not null default now(),
    closed_at timestamptz,                -- when the playgroup stops accepting joiners
    ended_at timestamptz,                 -- when the round itself completed
    status text not null default 'open'   -- 'open' | 'closed'
        check (status in ('open', 'closed')),
    name text                             -- optional display name like "Saturday at Hyde Park"
);

create index idx_playgroups_host on playgroups(host_id);
create index idx_playgroups_status on playgroups(status) where status = 'open';
create index idx_playgroups_started on playgroups(started_at desc);

create table playgroup_members (
    playgroup_id uuid not null references playgroups(id) on delete cascade,
    user_id uuid not null references auth.users(id) on delete cascade,
    round_id uuid references rounds(id) on delete set null,
    color text,                           -- hex or palette key, assigned at join
    joined_at timestamptz not null default now(),
    left_at timestamptz,
    primary key (playgroup_id, user_id)
);

create index idx_pm_user on playgroup_members(user_id);
create index idx_pm_round on playgroup_members(round_id);

create table playgroup_join_requests (
    id uuid primary key default gen_random_uuid(),
    playgroup_id uuid not null references playgroups(id) on delete cascade,
    requester_id uuid not null references auth.users(id) on delete cascade,
    requested_at timestamptz not null default now(),
    status text not null default 'pending'   -- 'pending' | 'accepted' | 'declined'
        check (status in ('pending', 'accepted', 'declined')),
    responded_at timestamptz,
    unique (playgroup_id, requester_id)
);
```

## RLS policy changes

### Existing tables (relax read-only to include shared-via-playgroup)

```sql
-- rounds: read = own OR member of a playgroup containing this round
drop policy "own_rounds" on rounds;

create policy "rounds_read" on rounds
    for select to authenticated
    using (
        user_id = auth.uid()
        or exists (
            select 1 from playgroup_members pm
            where pm.round_id = rounds.id and pm.user_id = auth.uid()
        )
    );

create policy "rounds_write" on rounds
    for insert to authenticated with check (user_id = auth.uid());
create policy "rounds_update" on rounds
    for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "rounds_delete" on rounds
    for delete to authenticated using (user_id = auth.uid());
```

Same pattern for `strokes`, `targets`, `round_holes` — read visibility flows through the parent round's policy:

```sql
-- example for strokes
drop policy "own_strokes" on strokes;

create policy "strokes_read" on strokes
    for select to authenticated
    using (
        exists (
            select 1 from rounds r
            where r.id = strokes.round_id
            and (
                r.user_id = auth.uid()
                or exists (
                    select 1 from playgroup_members pm
                    where pm.round_id = r.id and pm.user_id = auth.uid()
                )
            )
        )
    );

-- writes still owner-only via parent round
create policy "strokes_write" on strokes
    for insert to authenticated
    with check (
        exists (select 1 from rounds r where r.id = strokes.round_id and r.user_id = auth.uid())
    );
-- (similar update / delete)
```

### New tables

```sql
alter table playgroups enable row level security;
alter table playgroup_members enable row level security;
alter table playgroup_join_requests enable row level security;

-- playgroups: anyone authenticated can SELECT open playgroups (for proximity discovery
-- by the join flow); host can update; only members + host can see closed groups.
create policy "playgroups_read_open" on playgroups
    for select to authenticated
    using (
        status = 'open'
        or host_id = auth.uid()
        or exists (
            select 1 from playgroup_members pm
            where pm.playgroup_id = playgroups.id and pm.user_id = auth.uid()
        )
    );
create policy "playgroups_insert_self" on playgroups
    for insert to authenticated with check (host_id = auth.uid());
create policy "playgroups_host_update" on playgroups
    for update to authenticated using (host_id = auth.uid()) with check (host_id = auth.uid());

-- playgroup_members: see your own rows + rows in playgroups you're in;
-- INSERT requires the host to have accepted (enforced via the join_requests
-- table — the accept handler does the insert with the host's auth context).
create policy "pm_read_own" on playgroup_members
    for select to authenticated
    using (
        user_id = auth.uid()
        or exists (
            select 1 from playgroup_members pm2
            where pm2.playgroup_id = playgroup_members.playgroup_id and pm2.user_id = auth.uid()
        )
    );
create policy "pm_insert_host_only" on playgroup_members
    for insert to authenticated
    with check (
        exists (
            select 1 from playgroups pg
            where pg.id = playgroup_members.playgroup_id and pg.host_id = auth.uid()
        )
    );
create policy "pm_delete_self_or_host" on playgroup_members
    for delete to authenticated
    using (
        user_id = auth.uid()
        or exists (
            select 1 from playgroups pg
            where pg.id = playgroup_members.playgroup_id and pg.host_id = auth.uid()
        )
    );

-- join requests: requester can insert their own; host of the target playgroup
-- can SELECT/UPDATE; requester can SELECT their own.
create policy "jr_insert_self" on playgroup_join_requests
    for insert to authenticated with check (requester_id = auth.uid());
create policy "jr_read_self_or_host" on playgroup_join_requests
    for select to authenticated
    using (
        requester_id = auth.uid()
        or exists (
            select 1 from playgroups pg
            where pg.id = playgroup_join_requests.playgroup_id and pg.host_id = auth.uid()
        )
    );
create policy "jr_update_host_only" on playgroup_join_requests
    for update to authenticated
    using (
        exists (
            select 1 from playgroups pg
            where pg.id = playgroup_join_requests.playgroup_id and pg.host_id = auth.uid()
        )
    );
```

## Realtime additions

When in a playgroup, both watch and phone subscribe to additional channels:

- `playgroup:<id>` — fires on INSERT/UPDATE to `playgroup_members` (new joiner), `playgroup_join_requests` (host needs to see new pending), and `playgroups` itself (status transitions).
- For each member's `round_id`, the existing per-round subscriptions cover their `strokes`, `targets`, `round_holes`. Adding the new round_ids to the active subscription set when a member joins.

Lifecycle: subscriptions stay active while the active-round screen is visible (same as the round-scoped Realtime model already in place).

## Proximity check for Join Round

When User B taps Join, send their current GPS to a server-side function (Supabase Edge Function) or do a Postgrest query with a server-side filter. We need a server-side computation because we can't send all open playgroups + their hosts' GPS to every user — that defeats the privacy boundary.

Options:
1. **Edge Function** (`/functions/v1/find-nearby-playgroups`) — takes `{ lat, lon }` body, returns matching playgroups. Internal server-side query joins `playgroups` to a host-location source and computes haversine.
2. **Postgrest RPC function** — same idea but as a Postgres function callable via the SDK's `.rpc(...)`.

We need to know the host's GPS at host-time. Options:
- Snapshot host's GPS into the playgroup row at creation (`host_lat`, `host_lon` columns)
- Look up the host's current round's `course_id` → courses table for the course centroid

The playgroup row already has `course_id`. If both host and joiner use the same existing-course-first proximity check, they'll resolve to the same `course_id`. Then "nearby playgroup" simplifies to "playgroup whose course_id matches mine, status=open." No haversine needed at the server.

For the case where User A hosts at a brand-new course (no existing course row in DB), the playgroup gets the new course_id; User B's join-time existing-course-first check will find that course in the DB (since A just created it) and join via course_id match. Clean.

## Scorecard

**Layout: vertical** — holes go down the page. Columns:

| Hole | Par(s) | Tee yardage(s) | Player strokes |
|------|--------|----------------|----------------|

- **Hole** — 1..18 row order
- **Par** — one column normally; splits into multiple par columns only if tees in the group disagree on par for a hole (rare but real, e.g., Hyde Park women's tees are par 73, men's are par 72)
- **Tee yardage** — one column per tee currently in use by anyone in the group. Header = tee name from API ("Blue", "Red", "White")
- **Player strokes** — one column per player. Header = first name (truncated to ~3 chars if needed). Header text + cell text colored to that player's assigned palette color (same color used for their map markers)

**Filter columns to what the group is actually using.** Solo on Blue tees → 1 yardage col, 1 par col. Two players both on Blue → 1 yardage, 1 par, 2 stroke columns. Two players on Blue and Red → 2 yardage, 1 par (or 2 if pars differ), 2 stroke columns.

**Sizing target:** ~7 columns fits without scroll. So solo or up to 3 same-tee players, or 2 players on 2 tees, all comfortable. Edge cases (4 players × 4 tees) scroll horizontally. Same layout on phone and watch.

**Front-9 / Back-9 / Total breakdown** — clear visual break between holes 9 and 10. Three subtotal rows:
- After hole 9: "OUT" — par sum, yardage sum per tee column, stroke sum per player
- After hole 18: "IN" — same for back nine
- Below "IN": "TOT" — 18-hole grand totals

**Doubles as the color key for the map.** Player column colors in the scorecard match their map position dot, stroke markers, and connecting lines. No separate legend needed.

**Mid-round tee changes are captured in the data** (per-hole `tee_id` on `round_holes`) **but not visualized on the scorecard.** The yardage column shows the tee's card yardage as a static reference; the player's stroke cell shows their score with no visual indicator of which tee they were on. Real paper scorecards don't represent this either; if a player switches tees mid-round and the scorecard "looks weird" (e.g., wrong yardage column applied to those holes in their head), that's on them.

**Yardage ground truth = API data**, not GPS-derived. Two players' GPS readings will differ by 5-15 yards; using API data keeps the scorecard consistent across devices and sessions.

## Tee data + GolfCourseAPI integration

**GolfCourseAPI is the scorecard-metadata source.** It complements OSM, which remains the geometry source. GolfCourseAPI gives us per-tee per-hole yardage + handicap, plus course/slope/bogey ratings — none of which OSM reliably provides.

API key (free tier, 300 req/day): stored in Supabase + injected at build time, not committed to source.

**Endpoints used:**
- `GET /v1/search?search_query=<name>` — text search; returns full course detail in results
- `GET /v1/courses/{id}` — single-course lookup; same shape as search results

No location-based search exists. Matching strategy: search by the course name we got from OSM, then filter API results by location proximity (API's `location.latitude/longitude` clubhouse point vs OSM polygon centroid, within ~500m).

**Coverage observations from real probes:**
- Standard solo courses (Hyde Park Jacksonville, etc.): present, full data
- Pebble Beach: present, name slightly truncated ("Pebble Beach Gl") — fuzzy match needed
- Pinehurst: every numbered course present as a separate entry
- Bethpage: actually BETTER than OSM. Has all 5 named courses (Yellow / Blue / Black / Green / Red) as separate entries with their own scorecards. Solves the umbrella-polygon disambiguation problem OSM has at this resort.

**Coverage gap fallback** — when a course isn't in GolfCourseAPI:
- No tee selection picker (no tees to pick from)
- Scorecard has no yardage columns
- Par column populated from OSM hole tags where mappers added them (par row is sparse if not)
- All other scorecard machinery still works

**Cached locally in our DB** so subsequent rounds at the same course skip the API call and the resolver runs faster.

### Schema additions for tee data

Migration `00012_course_tees.sql`:

```sql
-- One row per course tee box. Cross-user shared (cached from GolfCourseAPI).
create table course_tees (
    id uuid primary key default gen_random_uuid(),
    course_id uuid not null references courses(id) on delete cascade,
    external_course_id text,           -- GolfCourseAPI course id
    tee_name text not null,            -- "Blue", "Red", "White", "Black", etc.
    gender text,                       -- 'male' | 'female' | null
    course_rating numeric(4,1),
    slope_rating integer,
    bogey_rating numeric(4,1),
    par_total integer,
    total_yards integer,
    total_meters integer,
    front_course_rating numeric(4,1),
    front_slope_rating integer,
    back_course_rating numeric(4,1),
    back_slope_rating integer,
    fetched_at timestamptz not null default now(),
    unique (course_id, tee_name, gender)
);

create index idx_course_tees_course on course_tees(course_id);

-- Per-hole data per tee (yardage + handicap + par-as-played-from-this-tee).
create table course_tee_holes (
    id uuid primary key default gen_random_uuid(),
    tee_id uuid not null references course_tees(id) on delete cascade,
    hole_number integer not null,
    par integer,
    yardage integer,
    handicap integer,
    unique (tee_id, hole_number)
);

create index idx_cth_tee on course_tee_holes(tee_id);

-- Round tracks which tee the user selected.
alter table rounds add column selected_tee_id uuid references course_tees(id);

-- Per-hole snapshot of which tee was active when the user played it (lets users
-- change tees mid-round without rewriting history; data captures the change
-- per-hole even though the scorecard doesn't visualize it).
alter table round_holes add column tee_id uuid references course_tees(id);
```

**RLS:** course_tees + course_tee_holes are publicly readable by authenticated users (cross-user shared cache, same as `osm_course_data`). INSERT requires authenticated. No DELETE policy.

### Tee selection UX

1. Round resolver runs (existing-course-first → OSM → GolfCourseAPI), data loaded
2. **Before** round play screen opens, present **tee picker modal** with all available tees from the API: tee_name, total_yards, par_total, course/slope rating
3. User taps a tee → `rounds.selected_tee_id` set; all 18 `round_holes` for this round get `tee_id` set to the selection
4. Round play screen opens; per-hole yardage display reads from `course_tee_holes.yardage` for the selected tee
5. **Mid-round change** — settings has "Change tee" option. Selecting a new tee updates `rounds.selected_tee_id` and updates the `tee_id` on all FUTURE unplayed `round_holes` (already-played holes keep their original tee_id)
6. **Coverage gap** — when course has no API tee data, skip the picker entirely; round starts straight into play; per-hole yardage display falls back to live distance from current GPS to green
7. **Multi-player** — each player picks their own tee at their own round-start. The scorecard surfaces the union of all tees in use across the group.

## Implementation order

This is the build sequence we agreed on, top to bottom:

1. **Update this doc** ✓
2. **GolfCourseAPI integration** — `GolfCourseAPIService` (search, course detail), schema migration `00012_course_tees.sql`, hook into RoundResolver after course pick, cache to `course_tees` + `course_tee_holes`
3. **Tee picker UI** — modal after resolver completes, before round opens; settings option for mid-round change
4. **Solo scorecard view** — single-player, single-tee variant of the layout. Replaces or augments existing `InRoundScorecardView`.
5. **Playgroup infrastructure** — migration `00011_playgroups.sql`, `PlaygroupService` (host/join/accept/decline/end), Multiplayer view in Settings, RLS updates, profile capture for first names
6. **Map color/marker system** — assign palette color on join, render player position dots in color, render stroke markers in lighter version of color, faint connecting lines between strokes (apply to single-player rounds too)
7. **Scorecard multi-player extensions** — column-per-player + multi-tee column logic + colored player columns
8. **Realtime additions for playgroups** — subscribe to playgroup channel + member round subs while active round screen visible
9. **Background time-based cleanup** — Supabase scheduled function to set `playgroups.status='closed'` on rows older than 6h still in `open`

## Out of scope for v1

- Friends list / persistent contacts
- Kick (replaced by accept-on-join)
- Push notifications (APNs)
- Voice chat or chat
- Stats segmentation between solo and shared rounds (multi-player rounds count in your stats normally)
- Cross-device player notification when their stroke is recorded by another (e.g., haptic on Mike's watch when Jared tees off)
- Shared round-level features beyond live positions + stroke markers + scorecard
- Visualizing per-hole tee changes on the scorecard

## Sync architecture for multiplayer (real-world constraints)

The original implementation subscribed to Supabase Realtime over a WebSocket on both phone and watch. That doesn't survive contact with the actual deployment environment:

**Hard constraints we discovered the hard way:**

- **Non-LTE Apple Watches cannot open WebSockets.** The phone-paired Bluetooth tether proxies `URLSession` HTTPS requests for the watch (OS-level mechanism, not app-level), but it does **not** proxy `URLSessionWebSocketTask`. WebSocket attempts on a non-LTE watch fail with `NSURLErrorDomain Code=-1009 "The Internet connection appears to be offline"` even when the phone has perfect signal.
- **iPhone "Always" location authorization is unrealistic UX-wise.** Without Always + active location updates + the `location` background mode, iOS suspends the GolfTracker app on the phone within seconds of backgrounding (= phone in pocket during a round, which is most of the time). Suspended app = no WebSocket, no polling, no anything. We ask for Always in Info.plist but iOS hides it from the first-time prompt; most users grant only "While Using App" and never see the upgrade prompt.
- **Conclusion: the phone cannot reliably hold a long-lived connection during a round.**

**The architecture that fits these constraints:**

- **Watch polls the database directly.** HTTPS via the phone-tether proxy. Works while the phone app is suspended (the OS handles proxying, not our app). Watch polls every 10–15 s for delta state during an active multiplayer round.
- **Phone is irrelevant for multiplayer sync.** The phone's WebSocket subscription stays in place when the app is foreground (snappy UX while looking at the phone) but nothing depends on it for correctness.
- **Polling is multiplayer-only.** Single-player sessions don't poll — the watch's local SwiftData copy of the round is authoritative because nobody else is writing it. SupabaseSync mirrors local writes to the DB for backup / cross-device, but no incoming traffic is needed.

**Tactics to keep watch polling cheap:**

- Conditional polling: `WHERE updated_at > <last_seen>` — most ticks return zero rows, ~200-byte response.
- Tight scope: poll only the active round + strokes for the current hole + active playgroup members. Course/club data doesn't change mid-round and isn't repolled.
- Adaptive interval: 10 s during active multiplayer, paused entirely solo. Pause when watch is `inactive` or `background` (`WKExtension.applicationState`).
- Single endpoint: one PostgREST query that returns all per-tick deltas as a combined response. One round-trip per tick, not N.

**WebSocket: kept as an enhancement, gated to LTE watches.** The reconnect helper (`RealtimeReconnect.subscribePersistently`) stays in place. LTE watches that can hold their own connection use it; the path is already wired and tested. Non-LTE watches never reach the WebSocket code path.

**What we lose under polling-only:**

- Sub-second push features. Specifically: walkie-talkie pre-alert ("X is talking…"), walkie-talkie audio streaming. These need true push; polling can't deliver them.

**Decision: walkie-talkie is gated to LTE watches.** Keep the existing `WalkieTalkie` + `PlaygroupChannel` broadcast wiring, but only activate it when the watch has independent connectivity. For the common case (non-LTE watch on the course), no walkie-talkie. The feature was always "nice to have," and the alternative — forcing every user onto an LTE-watch-only sync architecture — isn't worth it.

## Open / TODO before implementation

- Color palette specifics — exact ~6 hex values for player assignment (one per player slot in a playgroup)
- Player marker label format on the map — first-letter initial in a circle? full first name in a pill? — affects readability vs. pixel budget on the watch
- Whether the "Multiplayer" entry point lives only in Settings or also gets a prominent button in the round-start flow on the home screen
- API key handling — fetched from Supabase config at app launch, or compiled in via xcconfig (not in source)
