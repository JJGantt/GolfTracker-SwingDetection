-- Auto-close playgroups that have been open for >6h. Garbage collection
-- for forgotten/abandoned multiplayer sessions, so they stop showing up
-- in joiners' "Nearby" lists indefinitely.
--
-- Implementation: a pg_cron job that runs hourly. We update status +
-- closed_at + ended_at; member rows and strokes stay intact since the
-- round itself remains valid history (stats, playback, etc).
--
-- 6h is generous — average round is 4-4.5h, even slow ones rarely cross
-- 5h. Anyone who somehow stretches past 6h can just re-host.

create extension if not exists pg_cron;

-- Drop any prior schedule with the same name so this migration is
-- idempotent (re-running doesn't double-schedule).
select cron.unschedule('close_stale_playgroups')
where exists (
    select 1 from cron.job where jobname = 'close_stale_playgroups'
);

select cron.schedule(
    'close_stale_playgroups',
    '0 * * * *',  -- top of every hour
    $$
    update playgroups
    set status = 'closed',
        closed_at = coalesce(closed_at, now()),
        ended_at = coalesce(ended_at, now())
    where status = 'open'
      and started_at < now() - interval '6 hours';
    $$
);
