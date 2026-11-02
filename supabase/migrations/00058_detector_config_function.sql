-- The watch reads its detector thresholds through one function instead of the
-- table.
--
-- The watch runs the detector on the wrist, so every value in force reaches
-- every signed-in user's device and cannot be secret. What the table holds
-- beyond that does not need to leave the server: the per-row notes (what each
-- threshold does and why it sits where it does), when each was last tuned, and
-- whatever else is kept there. `detector_config_for_me` returns only the
-- resolved key → value set the caller's detector runs under, a user's own row
-- overriding the shared default exactly as `DetectorConfig` used to resolve it.
--
-- No client writes this table: thresholds are tuned with the service role
-- (`tune.py` in the algorithms repo), so the write policies go too. A user row
-- that already exists still applies to its owner; only the service role can
-- add or change one.
--
-- Builds before 75 select the table directly. Without the read policy they
-- keep the last config they cached, which is the set in force today.

create or replace function detector_config_for_me()
returns table (key text, value double precision)
language sql
stable
security definer
set search_path = public
as $$
    select coalesce(mine.key, base.key), coalesce(mine.value, base.value)
    from (select key, value from detector_config where user_id is null) base
    full join (select key, value from detector_config where user_id = auth.uid()) mine
        on mine.key = base.key
    where auth.uid() is not null
$$;

revoke all on function detector_config_for_me() from public, anon;
grant execute on function detector_config_for_me() to authenticated;

drop policy if exists detector_config_read on detector_config;
drop policy if exists detector_config_write_own on detector_config;
drop policy if exists detector_config_update_own on detector_config;
drop policy if exists detector_config_delete_own on detector_config;
