-- Insert policies on swing_events and the swing-motion bucket with no role clause.
-- Superseded by the owner-scoped policies in 00008 and 00009.

drop policy if exists "anon_insert_only" on swing_events;
create policy "allow_insert"
    on swing_events
    for insert
    with check (true);

drop policy if exists "anon_upload_swing_motion" on storage.objects;
create policy "allow_upload_swing_motion"
    on storage.objects
    for insert
    with check (bucket_id = 'swing-motion');

-- Clean up debug helper
drop function if exists public.whoami();
