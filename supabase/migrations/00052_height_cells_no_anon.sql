-- Supabase's default privileges grant EXECUTE on new public functions to anon directly, so the
-- `revoke ... from public` in 00045 left both SECURITY DEFINER height-map writers callable with the
-- publishable key that ships in the app. Signed-in clients keep upsert; replace stays service-only.
revoke execute on function upsert_course_height_cells(uuid, jsonb) from anon;
revoke execute on function replace_course_height_cells(uuid, jsonb) from anon;
