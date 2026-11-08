#!/usr/bin/env bash
# handler_test.sh — token lifecycle, static tree, 404, traversal, TTL.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TESTS_DIR/lib/assert.sh"
. "$TESTS_DIR/lib/server.sh"

sandbox="$(mktemp -d)"
trap 'server_stop; rm -rf -- "$sandbox"' EXIT

published_root="$sandbox/shared"
state_directory="$sandbox/state"
mkdir -p "$published_root/docs" "$published_root/data"
printf '#!/bin/sh\necho fixture-default\n' > "$published_root/docs/DEFAULT.sh"
printf 'id\tvalue\n1\tone\n' > "$published_root/data/table.tsv"

export TOKEN_TTL_SECONDS=300
server_start "$published_root" "$state_directory"

# --- token lifecycle --------------------------------------------------------
http_get /work
assert_status 200 "$HTTP_STATUS" "GET /work should create a token"
token="$HTTP_BODY"
assert_matches '^[0-9]+$' "$token" "token should be numeric"

http_get "/work/$token"
assert_status 200 "$HTTP_STATUS" "GET /work/<token> should return the command"
assert_equal 'echo hello-world' "$HTTP_BODY" "bound command"

http_post "/done/$token" 'output=hello-world'
assert_status 200 "$HTTP_STATUS" "POST /done/<token> should confirm"
assert_contains "$HTTP_BODY" "confirmed: $token" "confirmation body"

http_get "/work/$token"
assert_status 410 "$HTTP_STATUS" "a done token should be gone"

# --- dataset request --------------------------------------------------------
http_post /get "token=$token&dataset=sample"
assert_status 200 "$HTTP_STATUS" "known token should get the dataset"
assert_contains "$HTTP_BODY" 'dataset sample granted' "dataset body"

http_post /get "dataset=sample"
assert_status 400 "$HTTP_STATUS" "missing token should be rejected"

http_post /get "token=$token"
assert_status 400 "$HTTP_STATUS" "missing dataset should be rejected"

http_post /get 'token=does-not-exist&dataset=sample'
assert_status 403 "$HTTP_STATUS" "unknown token should be forbidden"

# --- static tree ------------------------------------------------------------
http_get /docs
assert_status 200 "$HTTP_STATUS" "directory should resolve to DEFAULT"
assert_contains "$HTTP_BODY" 'fixture-default' "DEFAULT content"

http_get /data/table.tsv
assert_status 200 "$HTTP_STATUS" "nested file should be served"
assert_contains "$HTTP_BODY" $'1\tone' "nested file content"

http_get /missing
assert_status 404 "$HTTP_STATUS" "missing path should be 404"

http_get_path_as_is /../etc/passwd
assert_status 404 "$HTTP_STATUS" "path traversal should be 404"

http_get_path_as_is '/data/../../etc/passwd'
assert_status 404 "$HTTP_STATUS" "nested traversal should be 404"

# --- token TTL --------------------------------------------------------------
server_stop
export TOKEN_TTL_SECONDS=1
server_start "$published_root" "$state_directory"

http_get /work
assert_status 200 "$HTTP_STATUS" "TTL server should create a token"
expiring_token="$HTTP_BODY"
sleep 2
http_get "/work/$expiring_token"
assert_status 410 "$HTTP_STATUS" "expired token should be gone"
