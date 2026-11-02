-- Everything stored for one user, deleted in one transaction: what "Delete My
-- Data" removes. Called only by the `delete-my-data` edge function (service
-- role), which verifies the caller and also removes their storage objects.
--
-- Shared data stays: shared (OSM) courses and their shared holes, and the
-- course height map, which is terrain built from everyone's rounds rather
-- than a record of anyone's.

create or replace function delete_user_data(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if p_user_id is null then
        raise exception 'user id required' using errcode = '22004';
    end if;
    delete from swing_test_note_events where user_id = p_user_id;
    delete from swing_test_notes where user_id = p_user_id;
    delete from false_negative_candidates where user_id = p_user_id;
    delete from false_negative_groups where user_id = p_user_id;
    delete from swing_events where user_id = p_user_id;
    delete from swing_test_sessions where user_id = p_user_id;
    delete from client_events where user_id = p_user_id;
    delete from round_altitude_readings where user_id = p_user_id;
    delete from playgroup_join_requests where requester_id = p_user_id;
    delete from playgroup_members where user_id = p_user_id;
    delete from playgroups where host_id = p_user_id;
    delete from course_hole_picks where user_id = p_user_id;
    delete from course_scorecard_picks where user_id = p_user_id;
    delete from course_scorecard_skips where user_id = p_user_id;
    delete from holes where owner_id = p_user_id;
    delete from rounds where user_id = p_user_id;
    delete from courses where created_by = p_user_id and osm_id is null;
    delete from club_sets where user_id = p_user_id;
    delete from clubs where user_id = p_user_id;
    delete from club_types where user_id = p_user_id;
    delete from detector_config where user_id = p_user_id;
    delete from user_test_state where user_id = p_user_id;
    delete from profiles where user_id = p_user_id;
end $$;

revoke execute on function delete_user_data(uuid) from public, anon, authenticated;
grant execute on function delete_user_data(uuid) to service_role;
