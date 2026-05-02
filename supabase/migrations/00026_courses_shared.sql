-- Restructure courses as a cross-user shared table.
--
-- Before this migration, "courses" was a per-user table with RLS scoped
-- to user_id. The result: every user re-resolved every course they
-- played, even if another user had already played the same physical
-- course. The OSM cache + GolfCourseAPI cache patched some of the cost,
-- but the schema itself forced redundant work and made the resolver more
-- complex than it needed to be (per-user proximity check → OSM fallback
-- → name-match-against-cache → external-id reuse plumbing).
--
-- After this migration:
--   - Courses are shared. One row per physical course.
--   - Proximity query against `courses.center_lat/lon` is THE first-stop
--     resolution path. Hit → list nearest, user picks. Miss → resolve via
--     OSM + GolfCourseAPI, INSERT a single shared row, done.
--   - The existing osm_course_data + course_tees + course_tee_holes
--     caches stay (course_tees is keyed by external_course_id from
--     GolfCourseAPI, useful for cross-user reuse). osm_course_data goes
--     away — its polygon payload now lives directly on the courses row
--     (osm_polygons jsonb), keyed by the courses row itself.
--   - "My courses" becomes a derived query (DISTINCT courses joined on
--     user's rounds), not a separate table.
--
-- RLS: courses + holes both become read-all-authenticated. Inserts open
-- (any signed-in user can register a new course). Updates restricted
-- to the creator OR rows where created_by is null (legacy / edge cases).

-- 1. Add new columns to courses.
alter table courses add column if not exists center_lat double precision;
alter table courses add column if not exists center_lon double precision;
alter table courses add column if not exists osm_id bigint;
alter table courses add column if not exists osm_polygons jsonb;

-- 2. Decouple courses from user_id ownership. Rename to created_by for
--    provenance, make nullable so legacy rows don't fail the constraint.
alter table courses rename column user_id to created_by;
alter table courses alter column created_by drop not null;

-- 3. Backfill center coords from any existing holes so existing courses
--    keep working. Skip rows with no holes (they're effectively dead).
update courses c
set
    center_lat = sub.center_lat,
    center_lon = sub.center_lon
from (
    select course_id,
           avg(latitude) as center_lat,
           avg(longitude) as center_lon
    from holes
    where course_id is not null
      and latitude is not null
      and longitude is not null
    group by course_id
) sub
where c.id = sub.course_id
  and c.center_lat is null;

-- 4. Uniqueness on osm_id and external_course_id when present, so two
--    users resolving the same course don't create duplicate rows.
create unique index if not exists ux_courses_osm_id
    on courses(osm_id) where osm_id is not null;
create unique index if not exists ux_courses_external_course_id
    on courses(external_course_id) where external_course_id is not null;

-- 5. Indexes for proximity queries. B-tree on each is enough since we
--    pre-filter by a coarse bounding box client-side; no PostGIS yet.
create index if not exists idx_courses_center_lat on courses(center_lat);
create index if not exists idx_courses_center_lon on courses(center_lon);

-- 6. RLS: drop the per-user policy, install shared.
drop policy if exists "own_courses" on courses;
drop policy if exists "courses_read_all" on courses;
create policy "courses_read_all" on courses
    for select to authenticated
    using (true);

drop policy if exists "courses_insert_authenticated" on courses;
create policy "courses_insert_authenticated" on courses
    for insert to authenticated
    with check (auth.uid() is not null);

drop policy if exists "courses_update_owner_or_legacy" on courses;
create policy "courses_update_owner_or_legacy" on courses
    for update to authenticated
    using (created_by = auth.uid() or created_by is null)
    with check (auth.uid() is not null);

drop policy if exists "courses_delete_owner" on courses;
create policy "courses_delete_owner" on courses
    for delete to authenticated
    using (created_by = auth.uid());

-- 7. holes RLS — change from "own via courses.user_id" to read-all when
--    course-attached. A hole row is course-attached when course_id is
--    not null (round_holes is a separate table).
drop policy if exists "own_holes" on holes;
create policy "holes_read_all" on holes
    for select to authenticated
    using (true);

create policy "holes_insert_authenticated" on holes
    for insert to authenticated
    with check (auth.uid() is not null);

create policy "holes_update_authenticated" on holes
    for update to authenticated
    using (auth.uid() is not null)
    with check (auth.uid() is not null);

create policy "holes_delete_authenticated" on holes
    for delete to authenticated
    using (auth.uid() is not null);

-- 8. Drop the now-superseded osm_course_data table. Polygon data moves
--    onto the courses row (osm_polygons column) where it logically
--    belongs — one row per physical course, no separate cache table.
drop table if exists osm_course_data;
