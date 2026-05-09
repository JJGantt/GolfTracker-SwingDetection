-- Per-user "this course isn't on GolfCourseAPI" votes.
--
-- When a user picks "Course not listed" in the scorecard picker, we record
-- a row here. The resolver counts distinct users with a row for the course
-- before running searchScorecard — if >= 3 users have voted "not listed,"
-- skip the API call going forward (search results for this course are
-- guaranteed to keep being useless / stub-only / wrong-state).
--
-- One row per (user, course). Re-picking "not listed" is idempotent via
-- ON CONFLICT DO NOTHING.

create table if not exists course_scorecard_skips (
    user_id    uuid not null references auth.users(id) on delete cascade,
    course_id  uuid not null references courses(id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (user_id, course_id)
);

create index if not exists idx_course_scorecard_skips_course
    on course_scorecard_skips(course_id);

alter table course_scorecard_skips enable row level security;

-- Read all: we need cross-user counts to decide whether to skip the API.
create policy css_read_all on course_scorecard_skips
    for select to authenticated using (true);

-- Users only insert their own row.
create policy css_insert_own on course_scorecard_skips
    for insert to authenticated with check (user_id = auth.uid());

-- Users can delete their own (in case they change their mind).
create policy css_delete_own on course_scorecard_skips
    for delete to authenticated using (user_id = auth.uid());
