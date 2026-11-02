#!/usr/bin/env bash
# What each kind of user may do with `courses` (migration 00055), asserted
# against the live project with real sign-ins. Creates throwaway users and
# courses and deletes them on exit (lib.sh).
#
#   supabase/tests/courses_rls.sh
set -euo pipefail
. "$(dirname "$0")/lib.sh"

# A shared OSM course everyone plays: Disney's Palm.
SHARED_COURSE=ba5e825c-8161-4606-9e48-52d5cbac4f4f
row() { admin "$U/rest/v1/courses?id=eq.$1&select=$2" | jq -c '.[0]'; }
new_id() { uuidgen | tr 'A-Z' 'a-z'; }
register() { # register <token> <id> <osm_id> <name> <external id|null> <polygons json|null>
    jq -n --arg id "$2" --argjson osm "$3" --arg name "$4" --argjson ext "$5" --argjson p "$6" \
        '{p_id: $id, p_name: $name, p_center_lat: 30, p_center_lon: -81, p_osm_id: $osm,
          p_external_course_id: $ext, p_osm_polygons: $p}' \
        | call "$1" -X POST "$U/rest/v1/rpc/register_osm_course" -d @-
}
store_blobs() { # store_blobs <token> <course id>
    call "$1" -X POST "$U/rest/v1/rpc/store_course_blob_detection" \
        -d "{\"p_course_id\":\"$2\",\"p_results\":{\"courseId\":\"$2\",\"generatedAt\":0,\"blobs\":[]}}"
}

echo "-- shared courses"
BEFORE=$(row "$SHARED_COURSE" 'name,osm_polygons,external_course_id,blob_detection_results')
check "anyone signed in reads a shared course" \
    "$(body "$(call "$A_TOKEN" "$U/rest/v1/courses?id=eq.$SHARED_COURSE&select=id")" | jq length)" 1
r=$(call "$A_TOKEN" -X PATCH "$U/rest/v1/courses?id=eq.$SHARED_COURSE" -H 'Prefer: return=representation' -d '{"name":"renamed"}')
check "a user cannot rename a shared course" "$(body "$r")" '[]'
r=$(call "$A_TOKEN" -X DELETE "$U/rest/v1/courses?id=eq.$SHARED_COURSE" -H 'Prefer: return=representation')
check "a user cannot delete a shared course" "$(body "$r")" '[]'
r=$(call "$A_TOKEN" -X POST "$U/rest/v1/courses" -d "{\"id\":\"$(new_id)\",\"name\":\"x\",\"osm_id\":$(fake_osm_id)}")
check "a user cannot insert a shared course directly" "$(status "$r")" 403
OSM_ID=$(row "$SHARED_COURSE" osm_id | jq .osm_id)
r=$(register "$A_TOKEN" "$(new_id)" "$OSM_ID" "renamed" null '{"holes":[],"greens":[]}')
check "registering an existing osm_id returns that course" "$(body "$r" | tr -d '"')" "$SHARED_COURSE"
check "and changes nothing it already had" \
    "$(row "$SHARED_COURSE" 'name,osm_polygons,external_course_id,blob_detection_results')" "$BEFORE"

echo "-- registering"
NEW=$(new_id); TEMP_COURSES+=("$NEW"); OSM=$(fake_osm_id)
r=$(register "$B_TOKEN" "$NEW" "$OSM" "rls test" null null)
check "a new osm_id registers a shared course with no owner" \
    "$(body "$r" | tr -d '"') $(row "$NEW" 'created_by,osm_id' | jq -c '[.created_by, .osm_id]')" "$NEW [null,$OSM]"
register "$A_TOKEN" "$(new_id)" "$OSM" "other name" '"rls-ext"' '{"holes":[],"greens":[],"tag":1}' >/dev/null
check "registering again fills in only what was missing" \
    "$(row "$NEW" 'name,external_course_id,osm_polygons' | jq -c '[.name, .external_course_id, .osm_polygons.tag]')" '["rls test","rls-ext",1]'
register "$A_TOKEN" "$(new_id)" "$OSM" "third" '"rls-ext-2"' '{"holes":[],"greens":[],"tag":2}' >/dev/null
check "and never overwrites it" \
    "$(row "$NEW" 'name,external_course_id,osm_polygons' | jq -c '[.name, .external_course_id, .osm_polygons.tag]')" '["rls test","rls-ext",1]'

echo "-- personal courses"
MINE=$(new_id); TEMP_COURSES+=("$MINE")
r=$(call "$A_TOKEN" -X POST "$U/rest/v1/courses" -d "{\"id\":\"$MINE\",\"name\":\"A's course\"}")
check "a user creates their own course" "$(status "$r")" 201
check "and owns it without saying so" "$(row "$MINE" created_by | jq -r .created_by)" "$A_ID"
r=$(call "$A_TOKEN" -X POST "$U/rest/v1/courses" -d "{\"id\":\"$(new_id)\",\"name\":\"x\",\"created_by\":\"$B_ID\"}")
check "a user cannot create a course for someone else" "$(status "$r")" 403
r=$(call "$A_TOKEN" -X PATCH "$U/rest/v1/courses?id=eq.$MINE" -H 'Prefer: return=representation' -d '{"name":"A renamed"}')
check "the owner renames it" "$(body "$r" | jq -r '.[0].name')" "A renamed"
r=$(call "$A_TOKEN" -X PATCH "$U/rest/v1/courses?id=eq.$MINE" -d "{\"osm_id\":$(fake_osm_id)}")
check "the owner cannot turn it into a shared course" "$(status "$r")" 403
check "another user cannot see it" \
    "$(body "$(call "$B_TOKEN" "$U/rest/v1/courses?id=eq.$MINE&select=id")")" '[]'
r=$(call "$B_TOKEN" -X PATCH "$U/rest/v1/courses?id=eq.$MINE" -H 'Prefer: return=representation' -d '{"name":"B was here"}')
check "another user cannot rename it" "$(body "$r")" '[]'
r=$(call "$B_TOKEN" -X DELETE "$U/rest/v1/courses?id=eq.$MINE" -H 'Prefer: return=representation')
check "another user cannot delete it" "$(body "$r")" '[]'
check "it is unchanged" "$(row "$MINE" name | jq -r .name)" "A renamed"

echo "-- green detector results"
check "a user stores results on a shared course" "$(body "$(store_blobs "$B_TOKEN" "$NEW")")" true
check "the owner stores results on their own course" "$(body "$(store_blobs "$A_TOKEN" "$MINE")")" true
check "another user cannot store results on it" "$(body "$(store_blobs "$B_TOKEN" "$MINE")")" false
check "storing results touches nothing else" "$(row "$NEW" name | jq -r .name)" "rls test"

r=$(call "$A_TOKEN" -X DELETE "$U/rest/v1/courses?id=eq.$MINE" -H 'Prefer: return=representation')
check "the owner deletes their own course" "$(body "$r" | jq length)" 1

echo "-- signed out"
r=$(curl -s -w ' %{http_code}' -H "apikey: $PK" "$U/rest/v1/courses?select=id&limit=1")
check "the publishable key alone reads nothing" "$(status "$r")" 401
r=$(curl -s -w ' %{http_code}' -H "apikey: $PK" -H 'Content-Type: application/json' -X POST \
    "$U/rest/v1/rpc/register_osm_course" \
    -d "{\"p_id\":\"$(new_id)\",\"p_name\":\"x\",\"p_center_lat\":0,\"p_center_lon\":0,\"p_osm_id\":$(fake_osm_id),\"p_external_course_id\":null,\"p_osm_polygons\":null}")
check "the publishable key alone registers nothing" "$(status "$r")" 401

finish
