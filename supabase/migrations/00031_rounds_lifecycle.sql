-- Round lifecycle: explicit end-of-round + activity tracking.
--
-- ended_at marks a round as finished — set by the manual "End Round" button,
-- the inactivity sweep (lastActivityAt > 1h), the off-course sweep (>2km from
-- every hole), and the auto-end-prior-round path when a new round starts.
-- The currentRound getter on both clients filters ended_at IS NULL.
--
-- last_activity_at is bumped on stroke add and hole-index change. A single
-- shared column means we don't need cross-device coordination — either device
-- updating it suffices, sync echoes propagate.

alter table rounds add column if not exists ended_at timestamptz;
alter table rounds add column if not exists last_activity_at timestamptz;

create index if not exists idx_rounds_ended_at on rounds(ended_at);
