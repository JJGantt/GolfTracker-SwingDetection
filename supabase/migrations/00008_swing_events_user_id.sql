-- 00008_swing_events_user_id.sql
-- Replace anonymous device_id ownership with proper auth.users ownership.
-- After this migration, the Watch must send swing_events with a user JWT
-- (not the anon key); see GolfWatch Watch App/Services/WatchAuthSession.swift.
--
-- All statements written idempotently so the migration is safe to re-apply
-- against a database where some pieces were manually applied in the past.

-- 1. Add user_id with default to auth.uid() so authed clients don't have to send it.
ALTER TABLE public.swing_events
    ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE public.swing_events
    ALTER COLUMN user_id SET DEFAULT auth.uid();

-- 2. Pre-existing rows were backfilled to the database's sole user here. That
--    one-off data statement named the user and has been removed from this file;
--    it matches no rows on any database created afterwards.

ALTER TABLE public.swing_events
    ALTER COLUMN user_id SET NOT NULL;

-- 3. device_id is no longer needed — calibration is per-user, not per-device.
ALTER TABLE public.swing_events DROP COLUMN IF EXISTS device_id;

CREATE INDEX IF NOT EXISTS swing_events_user_id_idx ON public.swing_events(user_id);

-- 4. Lock down with RLS. Each user only sees / writes / mutates their own rows.
ALTER TABLE public.swing_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS allow_insert ON public.swing_events;
DROP POLICY IF EXISTS swing_events_select_own ON public.swing_events;
DROP POLICY IF EXISTS swing_events_insert_own ON public.swing_events;
DROP POLICY IF EXISTS swing_events_update_own ON public.swing_events;
DROP POLICY IF EXISTS swing_events_delete_own ON public.swing_events;

CREATE POLICY swing_events_select_own
    ON public.swing_events FOR SELECT
    USING (user_id = auth.uid());

CREATE POLICY swing_events_insert_own
    ON public.swing_events FOR INSERT
    WITH CHECK (user_id = auth.uid());

CREATE POLICY swing_events_update_own
    ON public.swing_events FOR UPDATE
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

CREATE POLICY swing_events_delete_own
    ON public.swing_events FOR DELETE
    USING (user_id = auth.uid());
