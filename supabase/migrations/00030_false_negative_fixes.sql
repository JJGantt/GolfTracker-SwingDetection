-- Three fixes for the false-negative upload pipeline that were silently
-- breaking every manual stroke add in production:
--
-- 1. Drop FK on `stroke_id`. Manual stroke adds insert the stroke locally
--    and queue it for async Supabase sync. The FN group insert fires
--    immediately afterward — before the stroke has reached the server —
--    so the FK reference resolves to a non-existent row and the group
--    insert fails. The cascading effect: candidate inserts then fail their
--    own FK to the missing group. Soft reference is fine here; the column
--    stays for downstream joins, but the constraint is wrong for an
--    eventually-consistent write path.
--
-- 2. Storage RLS for the false-negatives sub-prefix. The existing
--    swing_motion_insert_own policy compares `(storage.foldername(name))[1]`
--    to `auth.uid()::text`. iOS / watchOS construct paths with
--    `UUID.uuidString` which is uppercase; auth.uid()::text is lowercase.
--    For top-level swing-event paths this happens to slip through (storage
--    normalizes the leading folder somewhere along the line — unclear
--    where, but empirically those uploads succeed). For the deeper
--    `<userId>/false_negatives/<group>/<pos>.csv` path it does NOT, and
--    every CSV upload returned 403 in the wild. We make the comparison
--    case-insensitive for both directions so the path case stops
--    mattering.
--
-- 3. (No schema change needed) The Swift upload site is unchanged — the
--    case-insensitive policy + dropped FK together unblock the existing
--    code paths.

alter table false_negative_groups
    drop constraint if exists false_negative_groups_stroke_id_fkey;

drop policy if exists swing_motion_select_own on storage.objects;
drop policy if exists swing_motion_insert_own on storage.objects;
drop policy if exists swing_motion_update_own on storage.objects;
drop policy if exists swing_motion_delete_own on storage.objects;

create policy swing_motion_select_own
    on storage.objects for select
    using (
        bucket_id = 'swing-motion'
        and lower((storage.foldername(name))[1]) = lower(auth.uid()::text)
    );

create policy swing_motion_insert_own
    on storage.objects for insert
    with check (
        bucket_id = 'swing-motion'
        and lower((storage.foldername(name))[1]) = lower(auth.uid()::text)
    );

create policy swing_motion_update_own
    on storage.objects for update
    using (
        bucket_id = 'swing-motion'
        and lower((storage.foldername(name))[1]) = lower(auth.uid()::text)
    )
    with check (
        bucket_id = 'swing-motion'
        and lower((storage.foldername(name))[1]) = lower(auth.uid()::text)
    );

create policy swing_motion_delete_own
    on storage.objects for delete
    using (
        bucket_id = 'swing-motion'
        and lower((storage.foldername(name))[1]) = lower(auth.uid()::text)
    );
