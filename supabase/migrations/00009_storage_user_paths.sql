-- 00009_storage_user_paths.sql
-- Re-key swing-motion storage objects from <deviceId>/ to <userId>/ folders
-- and replace the open RLS policies with auth.uid()-based ones so each user
-- only sees their own CSVs. Pairs with 00008_swing_events_user_id.sql.
--
-- All statements idempotent so safe to re-apply against partial state.

-- 1. Existing objects were moved into the database's sole user's folder here.
-- That one-off data statement named the user and has been removed from this
-- file; it matches no objects on any database created afterwards.

-- 2. Replace permissive policies with per-user policies keyed on the first folder.
-- Storage convention: object name is "<userId>/<eventId>.csv"; auth.uid()::text
-- must match the leading folder for any access.
DROP POLICY IF EXISTS allow_read_swing_motion ON storage.objects;
DROP POLICY IF EXISTS allow_upload_swing_motion ON storage.objects;
DROP POLICY IF EXISTS allow_delete_swing_motion ON storage.objects;
DROP POLICY IF EXISTS swing_motion_select_own ON storage.objects;
DROP POLICY IF EXISTS swing_motion_insert_own ON storage.objects;
DROP POLICY IF EXISTS swing_motion_update_own ON storage.objects;
DROP POLICY IF EXISTS swing_motion_delete_own ON storage.objects;

CREATE POLICY swing_motion_select_own
    ON storage.objects FOR SELECT
    USING (
        bucket_id = 'swing-motion'
        AND (storage.foldername(name))[1] = auth.uid()::text
    );

CREATE POLICY swing_motion_insert_own
    ON storage.objects FOR INSERT
    WITH CHECK (
        bucket_id = 'swing-motion'
        AND (storage.foldername(name))[1] = auth.uid()::text
    );

CREATE POLICY swing_motion_update_own
    ON storage.objects FOR UPDATE
    USING (
        bucket_id = 'swing-motion'
        AND (storage.foldername(name))[1] = auth.uid()::text
    )
    WITH CHECK (
        bucket_id = 'swing-motion'
        AND (storage.foldername(name))[1] = auth.uid()::text
    );

CREATE POLICY swing_motion_delete_own
    ON storage.objects FOR DELETE
    USING (
        bucket_id = 'swing-motion'
        AND (storage.foldername(name))[1] = auth.uid()::text
    );
