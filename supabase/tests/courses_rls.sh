#!/usr/bin/env bash
# What each kind of user may do with `courses` (migrations 00055, 00056) and
# what the `register-osm-course` edge function registers, asserted
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
register_args() { # register_args <id> <osm_id> <name> <external id|null> <polygons json|null>
    jq -n --arg id "$1" --argjson osm "$2" --arg name "$3" --argjson ext "$4" --argjson p "$5" \
        '{p_id: $id, p_name: $name, p_center_lat: 30, p_center_lon: -81, p_osm_id: $osm,
          p_external_course_id: $ext, p_osm_polygons: $p}'
}
# The database function, as the edge function (service role) calls it.
register() { register_args "$@" | admin -X POST "$U/rest/v1/rpc/register_osm_course" -d @-; }
# The edge function, as the app calls it.
register_fn() { call "$1" -X POST "$U/functions/v1/register-osm-course" -d "$2"; }
store_blobs() { # store_blobs <token> <course id> <tag>: prints the tag of the set now in force
    body "$(call "$1" -X POST "$U/rest/v1/rpc/store_course_blob_detection" \
        -d "{\"p_course_id\":\"$2\",\"p_results\":{\"courseId\":\"$2\",\"generatedAt\":\"2026-11-01T00:00:00.000\",\"blobs\":[],\"tag\":$3}}")" \
        | jq -c 'if . == null then null else .tag end'
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
r=$(register_args "$(new_id)" "$(fake_osm_id)" "x" null null | call "$A_TOKEN" -X POST "$U/rest/v1/rpc/register_osm_course" -d @-)
check "a user cannot call register_osm_course themselves" "$(status "$r")" 403
OSM_ID=$(row "$SHARED_COURSE" osm_id | jq .osm_id)
r=$(register "$(new_id)" "$OSM_ID" "renamed" null '{"holes":[],"greens":[]}')
check "registering an existing osm_id returns that course" "$(echo "$r" | tr -d '"')" "$SHARED_COURSE"
check "and changes nothing it already had" \
    "$(row "$SHARED_COURSE" 'name,osm_polygons,external_course_id,blob_detection_results')" "$BEFORE"

echo "-- registering (database function)"
NEW=$(new_id); TEMP_COURSES+=("$NEW"); OSM=$(fake_osm_id)
r=$(register "$NEW" "$OSM" "rls test" null null)
check "a new osm_id registers a shared course with no owner" \
    "$(echo "$r" | tr -d '"') $(row "$NEW" 'created_by,osm_id' | jq -c '[.created_by, .osm_id]')" "$NEW [null,$OSM]"
register "$(new_id)" "$OSM" "other name" '"rls-ext"' '{"holes":[],"greens":[],"tag":1}' >/dev/null
check "registering again fills in only what was missing" \
    "$(row "$NEW" 'name,external_course_id,osm_polygons' | jq -c '[.name, .external_course_id, .osm_polygons.tag]')" '["rls test","rls-ext",1]'
register "$(new_id)" "$OSM" "third" '"rls-ext-2"' '{"holes":[],"greens":[],"tag":2}' >/dev/null
check "and never overwrites it" \
    "$(row "$NEW" 'name,external_course_id,osm_polygons' | jq -c '[.name, .external_course_id, .osm_polygons.tag]')" '["rls test","rls-ext",1]'

echo "-- registering (edge function: the server fetches OSM)"
# Cypress Point (an OSM golf course way) and Don Dahvee Park (a park way).
GOLF_WAY=36435651; PARK_WAY=36307266
r=$(register_fn "$A_TOKEN" "{\"courseId\":\"$(new_id)\",\"osm\":{\"id\":$OSM_ID}}")
check "an osm_id already registered returns that course, untouched" \
    "$(body "$r" | jq -r .courseId) $(row "$SHARED_COURSE" 'name,osm_polygons,external_course_id,blob_detection_results' | md5)" \
    "$SHARED_COURSE $(echo "$BEFORE" | md5)"
r=$(register_fn "$A_TOKEN" "{\"courseId\":\"$(new_id)\",\"osm\":{\"type\":\"way\",\"id\":$PARK_WAY}}")
check "an OSM element that is not a golf course is refused" "$(status "$r")" 422
r=$(register_fn "$A_TOKEN" "{\"courseId\":\"$(new_id)\",\"osm\":{\"type\":\"way\",\"id\":99999999999}}")
check "an OSM id that does not exist is refused" "$(status "$r")" 422
EXISTING_GOLF=$(admin "$U/rest/v1/courses?osm_id=eq.$GOLF_WAY&select=id" | jq -r '.[0].id // empty')
if [ -z "$EXISTING_GOLF" ]; then
    REAL=$(new_id); TEMP_COURSES+=("$REAL")
    r=$(register_fn "$A_TOKEN" "{\"courseId\":\"$REAL\",\"osm\":{\"type\":\"way\",\"id\":$GOLF_WAY},\"siblings\":[{\"type\":\"way\",\"id\":$PARK_WAY}],\"externalCourseId\":\"not-a-cached-scorecard\"}")
    check "a golf course is registered from OSM's own data" \
        "$(status "$r") $(body "$r" | jq -c '[.courseId, .name, .externalCourseId, (.osmData.boundingPolygons | length), (.osmData.attribution | test("OpenStreetMap"))]')" \
        "200 [\"$REAL\",\"Cypress Point Golf Course\",null,1,true]"
    check "with no owner" "$(row "$REAL" created_by | jq -c .created_by)" null
    r=$(register_fn "$B_TOKEN" "{\"courseId\":\"$(new_id)\",\"osm\":{\"type\":\"way\",\"id\":$GOLF_WAY}}")
    check "a second registration of it returns the first course's id" "$(body "$r" | jq -r .courseId)" "$REAL"
else
    echo "skip Cypress Point is already a registered course ($EXISTING_GOLF)"
fi
r=$(curl -s -w ' %{http_code}' -H "apikey: $PK" -H 'Content-Type: application/json' -X POST "$U/functions/v1/register-osm-course" \
    -d "{\"courseId\":\"$(new_id)\",\"osm\":{\"type\":\"way\",\"id\":$GOLF_WAY}}")
check "signed out, the function registers nothing" "$(status "$r")" 401

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
check "the first run stored on a shared course stands" "$(store_blobs "$B_TOKEN" "$NEW" 1)" 1
check "a later run gets the stored set back instead" "$(store_blobs "$A_TOKEN" "$NEW" 2)" 1
check "the owner stores results on their own course" "$(store_blobs "$A_TOKEN" "$MINE" 1)" 1
check "and a new run replaces them" "$(store_blobs "$A_TOKEN" "$MINE" 2)" 2
check "another user cannot store results on it, nor see them" "$(store_blobs "$B_TOKEN" "$MINE" 3)" null
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
