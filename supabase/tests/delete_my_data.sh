#!/usr/bin/env bash
# What "Delete My Data" removes (the `delete-my-data` edge function, migration
# 00057): every row keyed to the user and every motion recording they stored,
# and nothing of anyone else's. Runs against the live project with throwaway
# users (lib.sh).
#
#   supabase/tests/delete_my_data.sh
set -euo pipefail
. "$(dirname "$0")/lib.sh"

new_id() { uuidgen | tr 'A-Z' 'a-z'; }
as_user() { local t=$1 table=$2 json=$3
    call "$t" -X POST "$U/rest/v1/$table" -H 'Prefer: return=minimal' -d "$json" >/dev/null; }
upload() { # upload <token> <path>
    curl -s -o /dev/null -w '%{http_code}' -H "apikey: $PK" -H "Authorization: Bearer $1" -H 'Content-Type: text/csv' \
        -X POST "$U/storage/v1/object/swing-motion/$2" --data-binary 't,x'; }
count() { # count <table> <owner column> <user id>
    admin "$U/rest/v1/$1?$2=eq.$3&select=$2" | jq length; }
objects() { # objects <folder>: entries listed under the folder (storage matches the name case-insensitively)
    admin -X POST "$U/storage/v1/object/list/swing-motion" -d "{\"prefix\":\"$1/\",\"limit\":1000}" | jq length; }

UPPER=$(echo "$A_ID" | tr 'a-z' 'A-Z')
COURSE=$(new_id); ROUND=$(new_id)
for who in A B; do
    tok=$(eval echo "\$${who}_TOKEN")
    as_user "$tok" swing_events '{"classification":"swing"}'
done
as_user "$A_TOKEN" swing_test_notes '{"text":"note"}'
as_user "$A_TOKEN" client_events '{"device":"test","event":"test"}'
as_user "$A_TOKEN" courses "{\"id\":\"$COURSE\",\"name\":\"mine\"}"
as_user "$A_TOKEN" rounds "{\"id\":\"$ROUND\",\"user_id\":\"$A_ID\",\"course_id\":\"$COURSE\",\"course_name\":\"mine\",\"date\":\"2026-11-01T00:00:00Z\"}"
as_user "$A_TOKEN" profiles "{\"user_id\":\"$A_ID\",\"first_name\":\"Test\"}"
check "the user's motion files upload" \
    "$(upload "$A_TOKEN" "$UPPER/$(new_id)_raw.csv") $(upload "$A_TOKEN" "$A_ID/false_negatives/$(new_id)/0.csv")" "200 200"
B_FILE="$B_ID/$(new_id)_raw.csv"; upload "$B_TOKEN" "$B_FILE" >/dev/null

check "before: the user has rows and files" \
    "$(count swing_events user_id "$A_ID") $(count rounds user_id "$A_ID") $(objects "$A_ID")" "1 1 2"

r=$(call "$A_TOKEN" -X POST "$U/functions/v1/delete-my-data")
check "Delete My Data succeeds" "$(status "$r") $(body "$r" | jq .objectsRemoved)" "200 2"

for t in swing_events swing_test_notes client_events rounds profiles; do
    check "no $t rows remain" "$(count "$t" user_id "$A_ID")" 0
done
check "no personal courses remain" "$(count courses created_by "$A_ID")" 0
check "no motion files remain, in either case of the folder name" "$(objects "$UPPER") $(objects "$A_ID")" "0 0"
check "another user's rows and files are untouched" \
    "$(count swing_events user_id "$B_ID") $(objects "$B_ID")" "1 1"
admin -X DELETE "$U/storage/v1/object/swing-motion" -d "{\"prefixes\":[\"$B_FILE\"]}" >/dev/null

r=$(curl -s -w ' %{http_code}' -H "apikey: $PK" -X POST "$U/functions/v1/delete-my-data")
check "signed out, it deletes nothing" "$(status "$r")" 401

finish
