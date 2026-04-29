-- Walkie-talkie audio is now sent via Realtime binary broadcast, NOT
-- persisted. The DB row + Storage blob were transit mechanisms; once we
-- moved to in-memory broadcast fan-out, both became dead weight.
--
-- Drop the table, the per-bucket storage policies, and the bucket itself.

drop policy if exists "pgmsg_read_co_members" on playgroup_messages;
drop policy if exists "pgmsg_insert_self" on playgroup_messages;
drop table if exists playgroup_messages;

drop policy if exists "pgaudio_read_co_members" on storage.objects;
drop policy if exists "pgaudio_upload_member" on storage.objects;

-- Note: the `playgroup-audio` bucket itself is left in place. Postgres
-- migrations can't delete storage buckets directly (only the Storage API
-- can), and an empty bucket with no policies costs nothing. Drop it from
-- the dashboard if desired.
