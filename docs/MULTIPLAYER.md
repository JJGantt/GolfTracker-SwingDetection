# Multiplayer Rounds — Design Spec

**Status:** Designed, not implemented. Scorecard view (single-player) is the prerequisite and goes first; multiplayer builds on it.

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

## Implementation order

When we come back to build this:
1. **Scorecard view (single-player)** — prerequisite, doesn't exist today.
2. **Migration 00011** for the three new tables + RLS policy updates on existing tables.
3. **Profile capture** for first-name source.
4. **PlaygroupService** (shared iOS + watchOS) — host, join, accept, decline, end.
5. **Multiplayer view** in Settings on both targets.
6. **Map rendering changes** — color per player, lighter stroke markers, faint connecting lines (apply to single-player too while we're at it).
7. **Scorecard extension** — multi-row layout for shared rounds.
8. **Realtime additions** — subscribe to playgroup channel + member round subs.
9. **Background time-based cleanup** — Supabase scheduled function to set `status='closed'` on playgroups older than 6h still in `open`.

## Out of scope for v1

- Friends list / persistent contacts
- Kick (replaced by accept-on-join)
- Push notifications (APNs)
- Voice chat or chat
- Stats segmentation between solo and shared rounds (multi-player rounds count in your stats normally)
- Cross-device player notification when their stroke is recorded by another (e.g., haptic on Mike's watch when Jared tees off)
- Shared round-level features beyond live positions + stroke markers + scorecard

## Open / TODO before implementation

- Scorecard wireframe — single-player layout, then multi-row variant.
- Color palette specifics — exact 6 hex values for player assignment.
- Player marker label format on the map — first-letter initial in a circle? full first name in a pill? — affects readability vs. pixel budget on the watch.
- Whether the "Multiplayer" entry point lives only in Settings or also gets a prominent button in the round-start flow on the home screen.
