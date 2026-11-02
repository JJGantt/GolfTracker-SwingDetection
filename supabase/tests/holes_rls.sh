#!/usr/bin/env bash
# What each kind of user may do with `holes` (migration 00053), asserted against
# the live project with real sign-ins. Creates throwaway users and a throwaway
# course and deletes them on exit (lib.sh).
#
#   supabase/tests/holes_rls.sh
set -euo pipefail
. "$(dirname "$0")/lib.sh"

# A full-tier OSM course with shared holes and none of anyone's own: Disney's Palm.
SHARED_COURSE=ba5e825c-8161-4606-9e48-52d5cbac4f4f

rpc_upsert() { # rpc_upsert <token> <id|null> <course> <number> <lat>
    local id=$2; [ "$id" != null ] && id="\"$id\""
    call "$1" -X POST "$U/rest/v1/rpc/upsert_my_course_hole" \
        -d "{\"p_id\":$id,\"p_course_id\":\"$3\",\"p_number\":$4,\"p_latitude\":$5,\"p_longitude\":-81,\"p_par\":4}"
}

echo "-- shared holes"
r=$(call "$A_TOKEN" "$U/rest/v1/holes?course_id=eq.$SHARED_COURSE&select=owner_id")
check "anyone reads the shared holes" "$(body "$r" | jq -c '[length > 0, (map(.owner_id) | unique)]')" '[true,[null]]'
SHARED_ID=$(body "$(call "$A_TOKEN" "$U/rest/v1/holes?course_id=eq.$SHARED_COURSE&number=eq.1&select=id")" | jq -r '.[0].id')
SHARED_LAT=$(body "$(admin "$U/rest/v1/holes?id=eq.$SHARED_ID&select=latitude")" | jq -r '.[0].latitude')
r=$(call "$A_TOKEN" -X PATCH "$U/rest/v1/holes?id=eq.$SHARED_ID" -H 'Prefer: return=representation' -d '{"latitude":0}')
check "a user cannot update a shared hole" "$(body "$r")" '[]'
r=$(call "$A_TOKEN" -X DELETE "$U/rest/v1/holes?id=eq.$SHARED_ID" -H 'Prefer: return=representation')
check "a user cannot delete a shared hole" "$(body "$r")" '[]'
check "the shared hole is unchanged" \
    "$(body "$(admin "$U/rest/v1/holes?id=eq.$SHARED_ID&select=latitude")" | jq -r '.[0].latitude')" "$SHARED_LAT"
r=$(call "$A_TOKEN" -X POST "$U/rest/v1/holes" -d "{\"id\":\"$(uuidgen)\",\"course_id\":\"$SHARED_COURSE\",\"number\":90,\"owner_id\":null}")
check "a user cannot insert a shared hole" "$(status "$r")" 403
r=$(call "$A_TOKEN" -X POST "$U/rest/v1/holes" -d "{\"id\":\"$(uuidgen)\",\"course_id\":\"$SHARED_COURSE\",\"number\":91,\"owner_id\":\"$B_ID\"}")
check "a user cannot insert a hole for someone else" "$(status "$r")" 403

echo "-- personal holes"
r=$(rpc_upsert "$A_TOKEN" "$SHARED_ID" "$SHARED_COURSE" 1 28.1)
A_HOLE=$(body "$r" | tr -d '"')
check "moving a shared hole gives the user their own row, not the shared id" \
    "$([ "$(status "$r")" == 200 ] && [ "$A_HOLE" != "$SHARED_ID" ] && echo yes)" yes
r=$(rpc_upsert "$A_TOKEN" null "$SHARED_COURSE" 1 28.2)
check "moving it again updates the same row" "$(body "$r" | tr -d '"')" "$A_HOLE"
r=$(call "$A_TOKEN" "$U/rest/v1/holes?course_id=eq.$SHARED_COURSE&number=eq.1&select=owner_id,latitude&order=owner_id.nullsfirst")
check "the owner sees the shared row and their own" "$(body "$r" | jq -c '[.[1].owner_id == "'"$A_ID"'", .[1].latitude]')" '[true,28.2]'
r=$(call "$B_TOKEN" "$U/rest/v1/holes?course_id=eq.$SHARED_COURSE&number=eq.1&select=owner_id")
check "another user sees only the shared row" "$(body "$r" | jq -c 'map(.owner_id)')" '[null]'
r=$(call "$B_TOKEN" "$U/rest/v1/holes?id=eq.$A_HOLE&select=id")
check "another user cannot read it by id" "$(body "$r")" '[]'
r=$(call "$B_TOKEN" -X PATCH "$U/rest/v1/holes?id=eq.$A_HOLE" -H 'Prefer: return=representation' -d '{"latitude":0}')
check "another user cannot update it" "$(body "$r")" '[]'
r=$(call "$B_TOKEN" -X DELETE "$U/rest/v1/holes?id=eq.$A_HOLE" -H 'Prefer: return=representation')
check "another user cannot delete it" "$(body "$r")" '[]'
rpc_upsert "$B_TOKEN" "$A_HOLE" "$SHARED_COURSE" 1 29 >/dev/null
call "$B_TOKEN" -X POST "$U/rest/v1/rpc/delete_my_course_hole" -d "{\"p_course_id\":\"$SHARED_COURSE\",\"p_number\":1}" >/dev/null
check "another user's RPCs, even passing its id, leave it alone" \
    "$(body "$(admin "$U/rest/v1/holes?id=eq.$A_HOLE&select=owner_id,latitude")" | jq -c '.[0] | [.owner_id == "'"$A_ID"'", .latitude]')" '[true,28.2]'
call "$A_TOKEN" -X POST "$U/rest/v1/rpc/delete_my_course_hole" -d "{\"p_course_id\":\"$SHARED_COURSE\",\"p_number\":1}" >/dev/null
check "the owner deletes their own; the shared row stays" \
    "$(body "$(admin "$U/rest/v1/holes?course_id=eq.$SHARED_COURSE&number=eq.1&select=owner_id")" | jq -c 'map(.owner_id)')" '[null]'

echo "-- deriving shared holes from OSM"
POLY=$(admin "$U/rest/v1/courses?id=eq.$SHARED_COURSE&select=osm_polygons" | jq -c '.[0].osm_polygons')
N=$(echo "$POLY" | jq '.holes | length')
register() { # register <token> <id> <osm_id> <polygons json>
    jq -n --arg id "$2" --argjson osm "$3" --argjson p "$4" \
        '{p_id: $id, p_name: "rls test", p_center_lat: 30, p_center_lon: -81, p_osm_id: $osm,
          p_external_course_id: null, p_osm_polygons: $p}' \
        | call "$1" -X POST "$U/rest/v1/rpc/register_osm_course" -d @-
}
TEMP_COURSE=$(uuidgen | tr 'A-Z' 'a-z'); TEMP_COURSES+=("$TEMP_COURSE")
register "$C_TOKEN" "$TEMP_COURSE" "$(fake_osm_id)" "$POLY" >/dev/null
check "registering a course derives one shared hole per OSM hole" \
    "$(admin "$U/rest/v1/holes?course_id=eq.$TEMP_COURSE&select=owner_id" | jq -c '[length, (map(.owner_id) | unique)]')" "[$N,[null]]"
r=$(call "$C_TOKEN" -X POST "$U/rest/v1/rpc/derive_osm_course_holes" -d "{\"p_course_id\":\"$TEMP_COURSE\"}")
check "derive again adds nothing" "$(body "$r")" 0
BROKEN=$(echo "$POLY" | jq -c '.holes[1].ref = "1"')   # a duplicate ref: order not determined
UNORDERED=$(uuidgen | tr 'A-Z' 'a-z'); TEMP_COURSES+=("$UNORDERED")
register "$C_TOKEN" "$UNORDERED" "$(fake_osm_id)" "$BROKEN" >/dev/null
check "a course whose OSM data does not determine the order gets no shared holes" \
    "$(admin "$U/rest/v1/holes?course_id=eq.$UNORDERED&select=id" | jq length)" 0
PERSONAL=$(uuidgen | tr 'A-Z' 'a-z')
jq -n --arg id "$PERSONAL" --argjson p "$POLY" '{id: $id, name: "rls test", osm_polygons: $p}' \
    | call "$C_TOKEN" -X POST "$U/rest/v1/courses" -d @- >/dev/null
TEMP_COURSES+=("$PERSONAL")
r=$(call "$C_TOKEN" -X POST "$U/rest/v1/rpc/derive_osm_course_holes" -d "{\"p_course_id\":\"$PERSONAL\"}")
check "a personal course carrying OSM data gets no shared holes" "$(body "$r")" 0

echo "-- signed out"
r=$(curl -s -w ' %{http_code}' -H "apikey: $PK" "$U/rest/v1/holes?select=id&limit=1")
check "the publishable key alone reads nothing" "$(status "$r")" 401
r=$(curl -s -w ' %{http_code}' -H "apikey: $PK" -H 'Content-Type: application/json' -X POST "$U/rest/v1/rpc/upsert_my_course_hole" \
    -d "{\"p_id\":null,\"p_course_id\":\"$SHARED_COURSE\",\"p_number\":1,\"p_latitude\":1,\"p_longitude\":1,\"p_par\":null}")
check "the publishable key alone writes nothing" "$(status "$r")" 401

finish
