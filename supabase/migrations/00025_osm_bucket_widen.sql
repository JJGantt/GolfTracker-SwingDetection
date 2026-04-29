-- Widen osm_course_data.gps_bucket_lat / gps_bucket_lon from numeric(5,2)
-- and numeric(6,2) to double precision.
--
-- Why: OSMCourseService uses two cache key strategies:
--   1. coordinate-based: lat/lon rounded to 0.01° → fits the old numeric
--      type fine.
--   2. OSM-id-based: lat = -1 sentinel, lon = the course's OSM id (e.g.
--      286113630). 9+ digit integers DO NOT fit numeric(6,2), and every
--      upsert via the OSM-id path was rejected by Postgres with a numeric
--      overflow error. The error was caught client-side and silently
--      logged, so the bug went unnoticed — osm_course_data had zero rows
--      despite many round-resolves.
--
-- double precision happily holds either coords or large integers, and the
-- existing unique (gps_bucket_lat, gps_bucket_lon) constraint still works.

alter table osm_course_data
    alter column gps_bucket_lat type double precision using gps_bucket_lat::double precision;

alter table osm_course_data
    alter column gps_bucket_lon type double precision using gps_bucket_lon::double precision;
