-- Make courses.osm_id a non-partial unique index.
--
-- Migration 00026 created ux_courses_osm_id as a partial unique index
-- (`where osm_id is not null`). Postgres-rest can't use partial indexes as
-- ON CONFLICT targets — every resolver INSERT failed with 42P10
-- "there is no unique or exclusion constraint matching the ON CONFLICT
-- specification", which silently re-ran the full Overpass + GolfCourseAPI
-- miss path on every round-start.
--
-- A non-partial unique index still allows multiple NULLs (Postgres treats
-- NULLs as distinct in unique indexes by default), so MapKit-fallback or
-- legacy rows with osm_id=NULL remain valid.

drop index if exists ux_courses_osm_id;
create unique index ux_courses_osm_id on courses(osm_id);

-- Same treatment for external_course_id, which has the same problem and
-- the same NULL-tolerance properties.
drop index if exists ux_courses_external_course_id;
create unique index ux_courses_external_course_id on courses(external_course_id);
