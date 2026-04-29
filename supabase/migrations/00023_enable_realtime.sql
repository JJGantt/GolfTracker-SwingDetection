-- Add the tables we subscribe to via Realtime postgres-changes to the
-- `supabase_realtime` publication. Without this, postgres-changes
-- subscriptions on the client return nothing — silently. We discovered
-- this when the cross-device test mode toggle wasn't reflecting back to
-- the UI: the DB write was succeeding, but the Realtime echo we depend
-- on to update local state never arrived. Same root cause for the
-- "ZERO realtime.apply events" we saw in earlier diagnostics.
--
-- Idempotent: ALTER PUBLICATION ADD TABLE errors if the table is already
-- a member, so we use a DO block that checks pg_publication_tables first.

do $$
declare
    target_tables text[] := array[
        'rounds',
        'courses',
        'holes',
        'round_holes',
        'strokes',
        'targets',
        'club_types',
        'clubs',
        'club_sets',
        'club_set_type_selections',
        'playgroups',
        'playgroup_members',
        'playgroup_join_requests',
        'profiles',
        'user_test_state'
    ];
    t text;
begin
    foreach t in array target_tables loop
        if not exists (
            select 1 from pg_publication_tables
            where pubname = 'supabase_realtime'
              and schemaname = 'public'
              and tablename = t
        ) then
            execute format('alter publication supabase_realtime add table public.%I', t);
        end if;
    end loop;
end $$;
