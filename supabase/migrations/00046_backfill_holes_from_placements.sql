-- Recover greens the user placed by hand into the course's shared hole record.
--
-- WHY THEY WERE LOST
--
-- `holes` had exactly one writer: `RoundResolver`, building rows from
-- `osmData.holes` and requiring an OSM `ref` and green point. So a course OSM
-- has never heard of got zero hole rows no matter how carefully its greens
-- were placed by hand.
--
-- The placements were not lost, only misfiled. Two copies exist:
--
--   * `round_holes.latitude/longitude` — the watch's `updateHole` writes the
--     ROUND's copy of the hole and calls `upsertRound`, which never touches
--     `holes`. Every green placed on the watch landed here and nowhere else.
--   * `course_hole_picks` — recorded the user's selection, but stored only a
--     `blob_id` when a polygon was picked, deliberately nulling lat/lon. All 15
--     Wolf Hollow picks have null coordinates, so this copy cannot be used to
--     recover position.
--
-- Measured before this migration:
--
--   course                     placed in rounds   rows in holes
--   Hyde Park Golf Club                      19              18
--   Wolf Hollow Golf Course                  15               0
--   Wekiva Golf Club                          8               0
--   Sweetwater Country Club                   2               0
--
-- Wolf Hollow: 10 rounds, 15 greens placed, nothing to aim at. The elevation
-- readout targets a green centroid from `holes`, so it had no target there at
-- all, and the height map's green refinement had nothing to anchor on.
--
-- WHAT THIS DOES
--
-- For every (course, hole number) that has a placement in some round but no row
-- in `holes`, insert one using the MOST RECENT placement — the latest edit is
-- the user's current opinion, and re-placing a green is exactly how a
-- correction is expressed.
--
-- Existing `holes` rows are left alone. Where OSM and a hand placement disagree
-- this migration takes no view; it only fills genuine absences. The client
-- change that accompanies this makes hand placement authoritative going
-- forward, via `upsertCourseHoleLocation`.

begin;

with placement as (
    select
        r.course_id,
        rh.number,
        rh.latitude,
        rh.longitude,
        rh.par,
        row_number() over (
            partition by r.course_id, rh.number
            order by r.date desc nulls last, rh.id desc
        ) as recency
    from round_holes rh
    join rounds r on r.id = rh.round_id
    -- Inner join, not a filter: some rounds reference a course_id with no row
    -- in `courses` (deleted or never synced). Those placements have nowhere to
    -- go, and inserting them would violate holes_course_id_fkey.
    join courses c on c.id = r.course_id
    where rh.latitude is not null
      and rh.longitude is not null
),
newest as (
    select course_id, number, latitude, longitude, par
    from placement
    where recency = 1
)
insert into holes (id, course_id, number, latitude, longitude, par, created_at, updated_at)
select gen_random_uuid(), n.course_id, n.number, n.latitude, n.longitude, n.par, now(), now()
from newest n
where not exists (
    select 1 from holes h
     where h.course_id = n.course_id
       and h.number = n.number
)
on conflict (course_id, number) do nothing;

commit;
