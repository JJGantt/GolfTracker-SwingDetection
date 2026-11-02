#!/usr/bin/env bash
# What a signed-in user can get at in detector_config (migration 00058): the
# resolved thresholds through detector_config_for_me, their own row overriding
# the default, and nothing from the table itself. A break here either stops
# new watches detecting (no config) or hands out the table's notes.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

DEFAULTS=$(admin "$U/rest/v1/detector_config?user_id=is.null&select=key" | jq length)
KEY=$(admin "$U/rest/v1/detector_config?user_id=is.null&select=key&limit=1" | jq -r '.[0].key')

r=$(call "$A_TOKEN" -X POST "$U/rest/v1/rpc/detector_config_for_me" -d '{}')
check "function returns every default key" "$(body "$r" | jq length)" "$DEFAULTS"
check "function returns key and value only" "$(body "$r" | jq -c '.[0] | keys')" '["key","value"]'

# A's own override wins for A and is invisible to B.
admin -X POST "$U/rest/v1/detector_config" -d "{\"user_id\":\"$A_ID\",\"key\":\"$KEY\",\"value\":-12345}" >/dev/null
r=$(call "$A_TOKEN" -X POST "$U/rest/v1/rpc/detector_config_for_me" -d '{}')
check "own override wins" "$(body "$r" | jq --arg k "$KEY" '[.[] | select(.key == $k)] | map(.value)' -c)" '[-12345]'
check "override does not add a row" "$(body "$r" | jq length)" "$DEFAULTS"
r=$(call "$B_TOKEN" -X POST "$U/rest/v1/rpc/detector_config_for_me" -d '{}')
check "another user's override is not applied" "$(body "$r" | jq --arg k "$KEY" '[.[] | select(.key == $k)] | map(.value) | index(-12345)')" "null"

r=$(call "$A_TOKEN" "$U/rest/v1/detector_config?select=*")
check "table select returns nothing" "$(body "$r")" "[]"
r=$(call "$A_TOKEN" -X POST "$U/rest/v1/detector_config" -d "{\"user_id\":\"$A_ID\",\"key\":\"x$TAG\",\"value\":1}")
check "client cannot insert" "$(status "$r")" "403"
r=$(call "$PK" -X POST "$U/rest/v1/rpc/detector_config_for_me" -d '{}')
check "anonymous cannot call the function" "$(status "$r")" "401"

# The user's row goes when the user does (on delete cascade); delete it anyway.
admin -X DELETE "$U/rest/v1/detector_config?user_id=eq.$A_ID" >/dev/null
finish
