-- Per-user scorecard pick votes.
--
-- When a user picks a GolfCourseAPI scorecard for a course, we store
-- the (user, course → external_course_id) tuple here. At round-start,
-- the resolver counts distinct user picks for the course:
--   - Consensus (>=3 distinct users AND >=75% picked the same
--     external_course_id) → silent pick, skip the picker entirely.
--     User has already been validated by the community.
--   - No consensus → present the picker with results from API search,
--     including any "X others picked this" badge for the leading vote.
--
-- One row per (user, course). Re-picking on the same course updates
-- the same row via ON CONFLICT DO UPDATE.

create table if not exists course_scorecard_picks (
    user_id              uuid not null references auth.users(id) on delete cascade,
    course_id            uuid not null references courses(id) on delete cascade,
    external_course_id   bigint not null,
    created_at           timestamptz not null default now(),
    updated_at           timestamptz not null default now(),
    primary key (user_id, course_id)
);

create index if not exists idx_course_scorecard_picks_course
    on course_scorecard_picks(course_id);

alter table course_scorecard_picks enable row level security;

-- Read all: cross-user counts drive the consensus check.
create policy csp_read_all on course_scorecard_picks
    for select to authenticated using (true);

create policy csp_insert_own on course_scorecard_picks
    for insert to authenticated with check (user_id = auth.uid());

create policy csp_update_own on course_scorecard_picks
    for update to authenticated
    using (user_id = auth.uid())
    with check (user_id = auth.uid());

create policy csp_delete_own on course_scorecard_picks
    for delete to authenticated using (user_id = auth.uid());
