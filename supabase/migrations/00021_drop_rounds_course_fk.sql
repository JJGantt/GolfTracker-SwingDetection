-- Drop the foreign key constraint on rounds.course_id.
--
-- The constraint was rejecting INSERTs from "Quick Start" rounds (manual
-- play off a recognized course), where the watch generates a synthetic
-- random courseId that doesn't reference a real courses row. Result:
-- Quick Start rounds were silently failing to upload to Supabase, which
-- broke cross-device "Continue Round" and other features that depend on
-- the round being in the DB.
--
-- We keep the column for the case when there IS a real course (the
-- resolver path populates it via SupabaseSync.upsertCourse), but it's
-- now a soft pointer rather than an enforced reference. course_name
-- (text) is the actual display field in the app.
--
-- The matching FK on playgroups.course_id stays intact — multiplayer is
-- a separate code path and we want strict course identity for hosting.

alter table rounds drop constraint if exists rounds_course_id_fkey;
