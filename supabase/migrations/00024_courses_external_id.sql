-- Add external_course_id to courses so the resolver can skip the
-- GolfCourseAPI Edge Function call on subsequent rounds at the same course.
--
-- Currently RoundResolver.resolveScorecard calls
-- GolfCourseAPIService.search(query:) on every round-start, even when we've
-- already resolved that course before and have its tee data cached. By
-- stashing the matched external_course_id on the courses row at first
-- resolve, future round-starts can read course_tees directly via
-- cachedTees(forExternalCourseId:) without burning another API call.

alter table courses
    add column if not exists external_course_id text;

create index if not exists idx_courses_external_course
    on courses(external_course_id) where external_course_id is not null;
