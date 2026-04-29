-- 00013_course_tees_external_keyed.sql
-- The cache should be keyed by external_course_id (the GolfCourseAPI course
-- id), not by the user's local courses.id. Reasoning: at API search time we
-- have results for courses the user hasn't picked yet — they have no local
-- courses.id. The cache exists at the global level (cross-user shared);
-- linking to a per-user courses row would defeat the cross-user benefit.
--
-- Fix: relax course_id to nullable, add unique constraint on the external key.

alter table course_tees alter column course_id drop not null;
alter table course_tees alter column external_course_id set not null;

-- Drop the old unique constraint that depended on course_id and replace with
-- one keyed on external_course_id + tee_name + gender (the real identity).
alter table course_tees drop constraint if exists course_tees_unique;
alter table course_tees add constraint course_tees_external_unique
    unique (external_course_id, tee_name, gender);
