-- Per-user per-course-hole green polygon picks.
--
-- When a user commits a placement in HolePlacementView for hole N at
-- course X, we record their chosen blob_id (or nil + lat/lon when they
-- bypassed blob-snap and dropped a manual marker). One row per user per
-- (course, hole) — re-saving from Edit Hole replaces it in place.
--
-- Resolution at round-start, per (course, hole_number):
--   1. THIS user has a row → use their blob_id (or manual coord)
--   2. Else >= 3 distinct users picked AND >= 75% share the same
--      blob_id → that's canonical for everyone else
--   3. Else → HolePlacementView for this user (they contribute a pick)
--
-- Manual picks (blob_id IS NULL) are excluded from the voting count —
-- you can't agree on something arbitrary. Manual still beats voting for
-- the user's own future rounds via rule 1.

create table if not exists course_hole_picks (
    user_id     uuid not null references auth.users(id) on delete cascade,
    course_id   uuid not null references courses(id) on delete cascade,
    hole_number int  not null,
    blob_id     uuid,
    latitude    double precision,
    longitude   double precision,
    par         int,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),
    primary key (user_id, course_id, hole_number)
);

create index if not exists idx_course_hole_picks_lookup
    on course_hole_picks(course_id, hole_number);

alter table course_hole_picks enable row level security;

create policy chp_read_all on course_hole_picks
    for select to authenticated using (true);

create policy chp_insert_own on course_hole_picks
    for insert to authenticated with check (user_id = auth.uid());

create policy chp_update_own on course_hole_picks
    for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy chp_delete_own on course_hole_picks
    for delete to authenticated using (user_id = auth.uid());
