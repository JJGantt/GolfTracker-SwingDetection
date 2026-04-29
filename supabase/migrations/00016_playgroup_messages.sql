-- Walkie-talkie messages for playgroups. Audio blob lives in Storage;
-- this row is the delivery notification (Realtime postgres-changes fires
-- and recipients pull the file by storage_path).
--
-- Pre-alert ("someone is about to talk") is handled via Realtime broadcast
-- on the playgroup channel — no DB row, no schema involved.

create table if not exists playgroup_messages (
    id uuid primary key default gen_random_uuid(),
    playgroup_id uuid not null references playgroups(id) on delete cascade,
    sender_id uuid not null references auth.users(id) on delete cascade,
    storage_path text not null,
    duration_ms integer,
    created_at timestamptz not null default now()
);

create index if not exists idx_pgmsg_playgroup_created
    on playgroup_messages(playgroup_id, created_at desc);

alter table playgroup_messages enable row level security;

-- Read: any current member of the playgroup can see messages.
drop policy if exists "pgmsg_read_co_members" on playgroup_messages;
create policy "pgmsg_read_co_members" on playgroup_messages
    for select to authenticated
    using (
        exists (
            select 1 from playgroup_members pm
            where pm.playgroup_id = playgroup_messages.playgroup_id
              and pm.user_id = auth.uid()
        )
    );

-- Insert: sender must be a member, sender_id must match auth.uid().
drop policy if exists "pgmsg_insert_self" on playgroup_messages;
create policy "pgmsg_insert_self" on playgroup_messages
    for insert to authenticated
    with check (
        sender_id = auth.uid()
        and exists (
            select 1 from playgroup_members pm
            where pm.playgroup_id = playgroup_messages.playgroup_id
              and pm.user_id = auth.uid()
        )
    );

-- Storage bucket for the audio blobs. Path convention:
--   {playgroup_id}/{message_id}.m4a
insert into storage.buckets (id, name, public)
values ('playgroup-audio', 'playgroup-audio', false)
on conflict (id) do nothing;

-- Storage RLS: read by co-members of the playgroup the path encodes.
drop policy if exists "pgaudio_read_co_members" on storage.objects;
create policy "pgaudio_read_co_members" on storage.objects
    for select to authenticated
    using (
        bucket_id = 'playgroup-audio'
        and exists (
            select 1 from playgroup_members pm
            where pm.playgroup_id::text = split_part(name, '/', 1)
              and pm.user_id = auth.uid()
        )
    );

-- Storage RLS: upload allowed if sender is a member of the playgroup the
-- path encodes.
drop policy if exists "pgaudio_upload_member" on storage.objects;
create policy "pgaudio_upload_member" on storage.objects
    for insert to authenticated
    with check (
        bucket_id = 'playgroup-audio'
        and exists (
            select 1 from playgroup_members pm
            where pm.playgroup_id::text = split_part(name, '/', 1)
              and pm.user_id = auth.uid()
        )
    );
