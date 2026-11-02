-- Anon cannot call either SECURITY DEFINER height-map writer. Supabase's default privileges grant
-- EXECUTE on new public functions to anon directly, so `revoke ... from public` (00045) does not
-- remove it; it is revoked from anon by name. Signed-in clients keep upsert; replace stays
-- service-only.
revoke execute on function upsert_course_height_cells(uuid, jsonb) from anon;
revoke execute on function replace_course_height_cells(uuid, jsonb) from anon;
