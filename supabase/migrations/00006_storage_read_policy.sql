-- Allow reading and deleting objects in swing-motion bucket.
-- Without this, uploads succeed but downloads return 404.
create policy "allow_read_swing_motion"
    on storage.objects
    for select
    using (bucket_id = 'swing-motion');

create policy "allow_delete_swing_motion"
    on storage.objects
    for delete
    using (bucket_id = 'swing-motion');
