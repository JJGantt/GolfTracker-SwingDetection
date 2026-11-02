-- `updated_at` on the rows the devices sync is stamped by the server, so it is
-- the order the rows were written in.
--
-- The watch gets server rows through the phone, and when the watch is out of
-- reach the phone queues them with WatchConnectivity's `transferUserInfo`,
-- which can deliver long after the watch has a newer copy of the same row
-- (from its own write's echo, or its own catch-up read). `RealtimeSync` drops
-- a row older than the version it already holds, which needs a version that
-- only moves forward. A client-sent `updated_at` is the sender's clock and
-- some writers send none, so the trigger overrides whatever arrives.
--
-- `round_holes` had no `updated_at`; it gets one.

alter table round_holes add column if not exists updated_at timestamptz not null default now();

create or replace function stamp_updated_at() returns trigger
language plpgsql
as $$
begin
    new.updated_at := clock_timestamp();
    return new;
end $$;

do $$
declare t text;
begin
    foreach t in array array['rounds', 'round_holes', 'strokes', 'targets', 'holes', 'courses'] loop
        execute format('drop trigger if exists %I_stamp_updated_at on %I', t, t);
        execute format('create trigger %I_stamp_updated_at before insert or update on %I
                        for each row execute function stamp_updated_at()', t, t);
    end loop;
end $$;
