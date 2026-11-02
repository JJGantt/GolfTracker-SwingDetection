#!/usr/bin/env bash
# What each kind of user may do with `holes` (migration 00053), asserted against
# the live project with real sign-ins.
#
# Creates three throwaway email users and one throwaway course, and deletes them
# all on exit. Needs the service-role key (to create and remove the users):
# $SUPABASE_SERVICE_ROLE_KEY, or the logged-in supabase CLI, which it asks.
#
#   supabase/tests/holes_rls.sh
set -euo pipefail

REF=oumnicnvayqrbfbljgyl
U=https://$REF.supabase.co
PK=sb_publishable_i0loB-AZw2qGokBJzHGSKA_VGgAgjBi
SR=${SUPABASE_SERVICE_ROLE_KEY:-$(supabase projects api-keys --project-ref "$REF" -o json 2>/dev/null \
    | jq -r '.[] | select(.name == "service_role") | .api_key')}
[ -n "$SR" ] || { echo "no service-role key" >&2; exit 2; }

# A full-tier OSM course with shared holes and none of anyone's own: Disney's Palm.
SHARED_COURSE=ba5e825c-8161-4606-9e48-52d5cbac4f4f
TAG=rls-$(date +%s)
FAILS=0
USERS=()
TEMP_COURSE=""

admin() { curl -s -H "apikey: $SR" -H "Authorization: Bearer $SR" -H 'Content-Type: application/json' "$@"; }
# call <token> <curl args...>: prints "<body> <status>"
call() { local t=$1; shift
       curl -s -w ' %{http_code}' -H "apikey: $PK" -H "Authorization: Bearer $t" -H 'Content-Type: application/json' "$@"; }
check() { # check <name> <actual> <expected>
    if [ "$2" == "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2], want [$3]"; FAILS=$((FAILS + 1)); fi; }
status() { echo "${1##* }"; }
body() { echo "${1% *}"; }

cleanup() {
    [ -n "$TEMP_COURSE" ] && admin -X DELETE "$U/rest/v1/courses?id=eq.$TEMP_COURSE" >/dev/null
    for id in ${USERS[@]+"${USERS[@]}"}; do admin -X DELETE "$U/auth/v1/admin/users/$id" >/dev/null; done
    return 0
}
trap cleanup EXIT

new_user() { # new_user <name>: creates the user, prints its id
    admin -X POST "$U/auth/v1/admin/users" \
        -d "{\"email\":\"$TAG-$1@example.com\",\"password\":\"Pw-$TAG-$1\",\"email_confirm\":true}" | jq -r .id
}
sign_in() { # sign_in <name>: prints an access token
    curl -s -X POST "$U/auth/v1/token?grant_type=password" -H "apikey: $PK" -H 'Content-Type: application/json' \
        -d "{\"email\":\"$TAG-$1@example.com\",\"password\":\"Pw-$TAG-$1\"}" | jq -r .access_token
}
A_ID=$(new_user a); USERS+=("$A_ID"); A_TOKEN=$(sign_in a)
B_ID=$(new_user b); USERS+=("$B_ID"); B_TOKEN=$(sign_in b)
C_ID=$(new_user c); USERS+=("$C_ID"); C_TOKEN=$(sign_in c)
for t in "$A_TOKEN" "$B_TOKEN" "$C_TOKEN"; do
    [ "${#t}" -gt 100 ] || { echo "could not sign in a test user" >&2; exit 2; }
done

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
TEMP_COURSE=$(uuidgen | tr 'A-Z' 'a-z')
POLY=$(admin "$U/rest/v1/courses?id=eq.$SHARED_COURSE&select=osm_polygons" | jq -c '.[0].osm_polygons')
N=$(echo "$POLY" | jq '.holes | length')
jq -n --arg id "$TEMP_COURSE" --argjson p "$POLY" '{id: $id, name: "rls test", osm_polygons: $p}' \
    | call "$C_TOKEN" -X POST "$U/rest/v1/courses" -d @- >/dev/null
r=$(call "$C_TOKEN" -X POST "$U/rest/v1/rpc/derive_osm_course_holes" -d "{\"p_course_id\":\"$TEMP_COURSE\"}")
check "derive adds one shared hole per OSM hole" "$(body "$r")" "$N"
r=$(call "$C_TOKEN" -X POST "$U/rest/v1/rpc/derive_osm_course_holes" -d "{\"p_course_id\":\"$TEMP_COURSE\"}")
check "derive again adds nothing" "$(body "$r")" 0
check "derived holes are shared" \
    "$(admin "$U/rest/v1/holes?course_id=eq.$TEMP_COURSE&select=owner_id" | jq -c '[length, (map(.owner_id) | unique)]')" "[$N,[null]]"
admin -X DELETE "$U/rest/v1/holes?course_id=eq.$TEMP_COURSE" >/dev/null
BROKEN=$(echo "$POLY" | jq -c '.holes[1].ref = "1"')   # a duplicate ref: order not determined
admin -X PATCH "$U/rest/v1/courses?id=eq.$TEMP_COURSE" -d "{\"osm_polygons\":$BROKEN}" >/dev/null
r=$(call "$C_TOKEN" -X POST "$U/rest/v1/rpc/derive_osm_course_holes" -d "{\"p_course_id\":\"$TEMP_COURSE\"}")
check "derive adds nothing when OSM does not determine the order" "$(body "$r")" 0

echo "-- signed out"
r=$(curl -s -w ' %{http_code}' -H "apikey: $PK" "$U/rest/v1/holes?select=id&limit=1")
check "the publishable key alone reads nothing" "$(status "$r")" 401
r=$(curl -s -w ' %{http_code}' -H "apikey: $PK" -H 'Content-Type: application/json' -X POST "$U/rest/v1/rpc/upsert_my_course_hole" \
    -d "{\"p_id\":null,\"p_course_id\":\"$SHARED_COURSE\",\"p_number\":1,\"p_latitude\":1,\"p_longitude\":1,\"p_par\":null}")
check "the publishable key alone writes nothing" "$(status "$r")" 401

echo
[ "$FAILS" -eq 0 ] && echo "all passed" || { echo "$FAILS failed"; exit 1; }
