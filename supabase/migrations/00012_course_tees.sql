-- 00012_course_tees.sql
-- Cache GolfCourseAPI scorecard data per-course: tees + per-tee per-hole
-- yardage/handicap/par. Cross-user shared (same as osm_course_data) — when
-- one user resolves a course, all subsequent rounds at that course skip the
-- external API call.
--
-- The Edge Function `golfcourse-search` is the only writer; the iOS/watchOS
-- apps read via PostgrestClient. RLS allows authenticated SELECT on both
-- tables; INSERT requires the service role (which the Edge Function uses).
--
-- All statements idempotent so this migration is safe to re-apply against
-- partial state.

create table if not exists course_tees (
    id uuid primary key default gen_random_uuid(),
    course_id uuid not null references courses(id) on delete cascade,
    -- GolfCourseAPI's numeric course id, stored as text for forward-compat
    -- with other potential providers.
    external_course_id text,
    tee_name text not null,             -- "Blue", "Red", "White", "Black", "Gold", etc.
    gender text,                        -- 'male' | 'female' | null
    course_rating numeric(4,1),
    slope_rating integer,
    bogey_rating numeric(5,1),
    par_total integer,
    total_yards integer,
    total_meters integer,
    front_course_rating numeric(4,1),
    front_slope_rating integer,
    front_bogey_rating numeric(5,1),
    back_course_rating numeric(4,1),
    back_slope_rating integer,
    back_bogey_rating numeric(5,1),
    fetched_at timestamptz not null default now(),
    constraint course_tees_unique unique (course_id, tee_name, gender)
);

create index if not exists idx_course_tees_course on course_tees(course_id);
create index if not exists idx_course_tees_external on course_tees(external_course_id);

-- Per-hole data per tee. par lives here (not on holes) because some courses
-- have different par values per tee (e.g., a hole that plays as par 4 from
-- the men's tee but par 5 from the women's tee).
create table if not exists course_tee_holes (
    id uuid primary key default gen_random_uuid(),
    tee_id uuid not null references course_tees(id) on delete cascade,
    hole_number integer not null,
    par integer,
    yardage integer,
    handicap integer,                   -- stroke index
    constraint course_tee_holes_unique unique (tee_id, hole_number)
);

create index if not exists idx_cth_tee on course_tee_holes(tee_id);

-- Round tracks which tee the user selected at round start. Mid-round changes
-- (via Settings) update this AND the tee_id on all unplayed round_holes.
alter table rounds add column if not exists selected_tee_id uuid references course_tees(id) on delete set null;

-- Per-hole snapshot of which tee was active when the user played it. Lets us
-- support mid-round tee changes without rewriting history — already-played
-- holes keep their original tee_id, future holes get the new selection.
alter table round_holes add column if not exists tee_id uuid references course_tees(id) on delete set null;

-- =============================================================================
-- RLS — public-read, service-role-write (mirrors osm_course_data pattern)
-- =============================================================================

alter table course_tees enable row level security;
alter table course_tee_holes enable row level security;

drop policy if exists "course_tees_read_all" on course_tees;
create policy "course_tees_read_all" on course_tees
    for select to authenticated
    using (true);

-- Authenticated INSERT/UPDATE allowed (Edge Function runs with anon key when
-- invoked from a logged-in user; service role bypasses RLS entirely). Keeps
-- the door open for app-direct cache writes if we ever need them.
drop policy if exists "course_tees_insert_authenticated" on course_tees;
create policy "course_tees_insert_authenticated" on course_tees
    for insert to authenticated
    with check (auth.uid() is not null);

drop policy if exists "course_tees_update_authenticated" on course_tees;
create policy "course_tees_update_authenticated" on course_tees
    for update to authenticated
    using (auth.uid() is not null)
    with check (auth.uid() is not null);

drop policy if exists "cth_read_all" on course_tee_holes;
create policy "cth_read_all" on course_tee_holes
    for select to authenticated
    using (true);

drop policy if exists "cth_insert_authenticated" on course_tee_holes;
create policy "cth_insert_authenticated" on course_tee_holes
    for insert to authenticated
    with check (auth.uid() is not null);

drop policy if exists "cth_update_authenticated" on course_tee_holes;
create policy "cth_update_authenticated" on course_tee_holes
    for update to authenticated
    using (auth.uid() is not null)
    with check (auth.uid() is not null);
