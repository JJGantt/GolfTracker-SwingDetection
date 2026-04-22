-- Fix RLS: publishable key maps to 'postgres' role, not 'anon'.
-- Drop the anon-specific policy and create one that works for all roles.

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
