-- 00014_playgroups.sql
-- Multiplayer rounds: shared sessions where multiple golfers can see each
-- other's positions + strokes + scores during play. See docs/MULTIPLAYER.md
-- for the full design.
--
-- Three new tables (playgroups, playgroup_members, playgroup_join_requests)
-- + a profiles table for first-name capture, plus RLS updates on existing
-- tables (rounds/strokes/targets/round_holes) to allow co-member READs.
-- WRITEs stay owner-only.
--
-- Tables are all created first, then policies — policies cross-reference
-- tables (e.g., playgroups RLS reads from playgroup_members), so all
-- structures need to exist before any policy is declared.

-- =============================================================================
-- TABLES
-- =============================================================================

create table if not exists profiles (
    user_id uuid primary key references auth.users(id) on delete cascade,
    first_name text,
    display_name text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists playgroups (
    id uuid primary key default gen_random_uuid(),
    host_id uuid not null references auth.users(id) on delete cascade,
    course_id uuid references courses(id) on delete set null,
    course_name text not null,
    started_at timestamptz not null default now(),
    closed_at timestamptz,
    ended_at timestamptz,
    status text not null default 'open'
        check (status in ('open', 'closed')),
    name text
);

create index if not exists idx_playgroups_host on playgroups(host_id);
create index if not exists idx_playgroups_status_open on playgroups(status) where status = 'open';
create index if not exists idx_playgroups_started on playgroups(started_at desc);
create index if not exists idx_playgroups_course on playgroups(course_id);

create table if not exists playgroup_members (
    playgroup_id uuid not null references playgroups(id) on delete cascade,
    user_id uuid not null references auth.users(id) on delete cascade,
    round_id uuid references rounds(id) on delete set null,
    color text,
    joined_at timestamptz not null default now(),
    left_at timestamptz,
    primary key (playgroup_id, user_id)
);

create index if not exists idx_pm_user on playgroup_members(user_id);
create index if not exists idx_pm_round on playgroup_members(round_id);

create table if not exists playgroup_join_requests (
    id uuid primary key default gen_random_uuid(),
    playgroup_id uuid not null references playgroups(id) on delete cascade,
    requester_id uuid not null references auth.users(id) on delete cascade,
    requested_at timestamptz not null default now(),
    status text not null default 'pending'
        check (status in ('pending', 'accepted', 'declined')),
    responded_at timestamptz,
    unique (playgroup_id, requester_id)
);

create index if not exists idx_jr_playgroup_pending on playgroup_join_requests(playgroup_id) where status = 'pending';
create index if not exists idx_jr_requester on playgroup_join_requests(requester_id);

-- =============================================================================
-- RLS — enable on all new tables
-- =============================================================================

alter table profiles enable row level security;
alter table playgroups enable row level security;
alter table playgroup_members enable row level security;
alter table playgroup_join_requests enable row level security;

-- =============================================================================
-- profiles policies
-- =============================================================================

drop policy if exists "profiles_read_all" on profiles;
create policy "profiles_read_all" on profiles
    for select to authenticated
    using (true);

drop policy if exists "profiles_upsert_own" on profiles;
create policy "profiles_upsert_own" on profiles
    for insert to authenticated
    with check (user_id = auth.uid());

drop policy if exists "profiles_update_own" on profiles;
create policy "profiles_update_own" on profiles
    for update to authenticated
    using (user_id = auth.uid())
    with check (user_id = auth.uid());

-- =============================================================================
-- playgroups policies
-- =============================================================================

drop policy if exists "playgroups_read" on playgroups;
create policy "playgroups_read" on playgroups
    for select to authenticated
    using (
        status = 'open'
        or host_id = auth.uid()
        or exists (
            select 1 from playgroup_members pm
            where pm.playgroup_id = playgroups.id and pm.user_id = auth.uid()
        )
    );

drop policy if exists "playgroups_insert_self" on playgroups;
create policy "playgroups_insert_self" on playgroups
    for insert to authenticated
    with check (host_id = auth.uid());

drop policy if exists "playgroups_host_update" on playgroups;
create policy "playgroups_host_update" on playgroups
    for update to authenticated
    using (host_id = auth.uid())
    with check (host_id = auth.uid());

-- =============================================================================
-- playgroup_members policies
-- =============================================================================

drop policy if exists "pm_read_co_members" on playgroup_members;
create policy "pm_read_co_members" on playgroup_members
    for select to authenticated
    using (
        user_id = auth.uid()
        or exists (
            select 1 from playgroup_members pm2
            where pm2.playgroup_id = playgroup_members.playgroup_id
              and pm2.user_id = auth.uid()
        )
    );

drop policy if exists "pm_insert_host_only" on playgroup_members;
create policy "pm_insert_host_only" on playgroup_members
    for insert to authenticated
    with check (
        exists (
            select 1 from playgroups pg
            where pg.id = playgroup_members.playgroup_id
              and pg.host_id = auth.uid()
        )
    );

drop policy if exists "pm_update_self_or_host" on playgroup_members;
create policy "pm_update_self_or_host" on playgroup_members
    for update to authenticated
    using (
        user_id = auth.uid()
        or exists (
            select 1 from playgroups pg
            where pg.id = playgroup_members.playgroup_id and pg.host_id = auth.uid()
        )
    )
    with check (
        user_id = auth.uid()
        or exists (
            select 1 from playgroups pg
            where pg.id = playgroup_members.playgroup_id and pg.host_id = auth.uid()
        )
    );

drop policy if exists "pm_delete_self_or_host" on playgroup_members;
create policy "pm_delete_self_or_host" on playgroup_members
    for delete to authenticated
    using (
        user_id = auth.uid()
        or exists (
            select 1 from playgroups pg
            where pg.id = playgroup_members.playgroup_id and pg.host_id = auth.uid()
        )
    );

-- =============================================================================
-- playgroup_join_requests policies
-- =============================================================================

drop policy if exists "jr_insert_self" on playgroup_join_requests;
create policy "jr_insert_self" on playgroup_join_requests
    for insert to authenticated
    with check (requester_id = auth.uid());

drop policy if exists "jr_read_self_or_host" on playgroup_join_requests;
create policy "jr_read_self_or_host" on playgroup_join_requests
    for select to authenticated
    using (
        requester_id = auth.uid()
        or exists (
            select 1 from playgroups pg
            where pg.id = playgroup_join_requests.playgroup_id and pg.host_id = auth.uid()
        )
    );

drop policy if exists "jr_update_host_only" on playgroup_join_requests;
create policy "jr_update_host_only" on playgroup_join_requests
    for update to authenticated
    using (
        exists (
            select 1 from playgroups pg
            where pg.id = playgroup_join_requests.playgroup_id and pg.host_id = auth.uid()
        )
    )
    with check (
        exists (
            select 1 from playgroups pg
            where pg.id = playgroup_join_requests.playgroup_id and pg.host_id = auth.uid()
        )
    );

-- =============================================================================
-- Existing-table RLS updates: relax read to allow co-member visibility
-- =============================================================================

drop policy if exists "own_rounds" on rounds;
drop policy if exists "rounds_read" on rounds;
drop policy if exists "rounds_write" on rounds;
drop policy if exists "rounds_update" on rounds;
drop policy if exists "rounds_delete" on rounds;

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
    for insert to authenticated
    with check (user_id = auth.uid());

create policy "rounds_update" on rounds
    for update to authenticated
    using (user_id = auth.uid())
    with check (user_id = auth.uid());

create policy "rounds_delete" on rounds
    for delete to authenticated
    using (user_id = auth.uid());

drop policy if exists "own_strokes" on strokes;
drop policy if exists "strokes_read" on strokes;
drop policy if exists "strokes_write" on strokes;
drop policy if exists "strokes_update" on strokes;
drop policy if exists "strokes_delete" on strokes;

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

create policy "strokes_write" on strokes
    for insert to authenticated
    with check (
        exists (select 1 from rounds r where r.id = strokes.round_id and r.user_id = auth.uid())
    );

create policy "strokes_update" on strokes
    for update to authenticated
    using (
        exists (select 1 from rounds r where r.id = strokes.round_id and r.user_id = auth.uid())
    );

create policy "strokes_delete" on strokes
    for delete to authenticated
    using (
        exists (select 1 from rounds r where r.id = strokes.round_id and r.user_id = auth.uid())
    );

drop policy if exists "own_targets" on targets;
drop policy if exists "targets_read" on targets;
drop policy if exists "targets_write" on targets;
drop policy if exists "targets_update" on targets;
drop policy if exists "targets_delete" on targets;

create policy "targets_read" on targets
    for select to authenticated
    using (
        exists (
            select 1 from rounds r
            where r.id = targets.round_id
            and (
                r.user_id = auth.uid()
                or exists (
                    select 1 from playgroup_members pm
                    where pm.round_id = r.id and pm.user_id = auth.uid()
                )
            )
        )
    );

create policy "targets_write" on targets
    for insert to authenticated
    with check (
        exists (select 1 from rounds r where r.id = targets.round_id and r.user_id = auth.uid())
    );

create policy "targets_update" on targets
    for update to authenticated
    using (
        exists (select 1 from rounds r where r.id = targets.round_id and r.user_id = auth.uid())
    );

create policy "targets_delete" on targets
    for delete to authenticated
    using (
        exists (select 1 from rounds r where r.id = targets.round_id and r.user_id = auth.uid())
    );

drop policy if exists "own_round_holes" on round_holes;
drop policy if exists "round_holes_read" on round_holes;
drop policy if exists "round_holes_write" on round_holes;
drop policy if exists "round_holes_update" on round_holes;
drop policy if exists "round_holes_delete" on round_holes;

create policy "round_holes_read" on round_holes
    for select to authenticated
    using (
        exists (
            select 1 from rounds r
            where r.id = round_holes.round_id
            and (
                r.user_id = auth.uid()
                or exists (
                    select 1 from playgroup_members pm
                    where pm.round_id = r.id and pm.user_id = auth.uid()
                )
            )
        )
    );

create policy "round_holes_write" on round_holes
    for insert to authenticated
    with check (
        exists (select 1 from rounds r where r.id = round_holes.round_id and r.user_id = auth.uid())
    );

create policy "round_holes_update" on round_holes
    for update to authenticated
    using (
        exists (select 1 from rounds r where r.id = round_holes.round_id and r.user_id = auth.uid())
    );

create policy "round_holes_delete" on round_holes
    for delete to authenticated
    using (
        exists (select 1 from rounds r where r.id = round_holes.round_id and r.user_id = auth.uid())
    );
