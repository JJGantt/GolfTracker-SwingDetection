# Shared by the *_rls.sh scripts: keys, three throwaway users (A, B, C) signed
# in, request helpers, and cleanup on exit. Source it; do not run it.
#
# Needs the service-role key (to create and remove the users and anything
# registered under TEMP_COURSES): $SUPABASE_SERVICE_ROLE_KEY, or the logged-in
# supabase CLI, which it asks.

REF=oumnicnvayqrbfbljgyl
U=https://$REF.supabase.co
PK=sb_publishable_i0loB-AZw2qGokBJzHGSKA_VGgAgjBi
SR=${SUPABASE_SERVICE_ROLE_KEY:-$(supabase projects api-keys --project-ref "$REF" -o json 2>/dev/null \
    | jq -r '.[] | select(.name == "service_role") | .api_key')}
[ -n "$SR" ] || { echo "no service-role key" >&2; exit 2; }

TAG=rls-$(date +%s)
FAILS=0
USERS=()
TEMP_COURSES=()

admin() { curl -s -H "apikey: $SR" -H "Authorization: Bearer $SR" -H 'Content-Type: application/json' "$@"; }
# call <token> <curl args...>: prints "<body> <status>"
call() { local t=$1; shift
       curl -s -w ' %{http_code}' -H "apikey: $PK" -H "Authorization: Bearer $t" -H 'Content-Type: application/json' "$@"; }
check() { # check <name> <actual> <expected>
    if [ "$2" == "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2], want [$3]"; FAILS=$((FAILS + 1)); fi; }
status() { echo "${1##* }"; }
body() { echo "${1% *}"; }
# A random osm_id no real course has (real ones are positive).
fake_osm_id() { echo "-$(( (RANDOM << 15 | RANDOM) + 1 ))"; }

cleanup() {
    for id in ${TEMP_COURSES[@]+"${TEMP_COURSES[@]}"}; do admin -X DELETE "$U/rest/v1/courses?id=eq.$id" >/dev/null; done
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

finish() {
    echo
    [ "$FAILS" -eq 0 ] && echo "all passed" || { echo "$FAILS failed"; exit 1; }
}
