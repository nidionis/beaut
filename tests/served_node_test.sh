#!/usr/bin/env bash
# served_node_test.sh — `curl /node | sh` with zero client files, and /join
# stays unpublished.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TESTS_DIR/lib/assert.sh"
. "$TESTS_DIR/lib/server.sh"

sandbox="$(mktemp -d)"
trap 'server_stop; rm -rf -- "$sandbox"' EXIT

published_root="$sandbox/shared"
state_directory="$sandbox/state"
mkdir -p "$published_root/node"

export SERVER_PORT="$(server_pick_free_port)"
server_start "$published_root" "$state_directory"

artifact="$published_root/node/DEFAULT.sh"
bash "$PROJECT_ROOT/scripts/build_published_node.sh" \
  127.0.0.1 "$SERVER_PORT" > "$artifact"
chmod 755 "$artifact"

# The artifact is a POSIX sh script with the address baked in and no sources.
artifact_source="$(cat "$artifact")"
assert_contains "$artifact_source" '#!/bin/sh' "artifact shebang"
assert_contains "$artifact_source" "SERVER_HOST='127.0.0.1'" "baked server host"
assert_contains "$artifact_source" "HTTP_PORT='$SERVER_PORT'" "baked http port"
assert_not_contains "$artifact_source" 'BASH_SOURCE' "no BASH_SOURCE dependency"
assert_not_contains "$artifact_source" '"$SCRIPT_DIR' "no sourced files"
assert_not_contains "$artifact_source" 'set -uo pipefail' "no bash-only pipefail"
bash -n "$artifact"
if command -v dash >/dev/null 2>&1; then
  dash -n "$artifact"
fi

# Run exactly the advertised command from an empty working directory.
empty_directory="$sandbox/empty-cwd"
mkdir -p "$empty_directory"
node_output="$(cd "$empty_directory" && curl -fsS "$SERVER_URL/node" | sh 2>&1)"
assert_contains "$node_output" 'token received:' "node claims a token"
assert_contains "$node_output" 'command: echo hello-world' "node fetches the command"
assert_contains "$node_output" 'result sent to /done/' "node reports the result"
assert_contains "$node_output" '(exit: 0)' "command succeeded"
assert_equal "" "$(ls -A "$empty_directory")" "node leaves no client files"

# /join must not be served anymore.
http_get /join
assert_status 404 "$HTTP_STATUS" "/join should be unpublished"

if grep -q 'wireguard_join.sh shared/join' "$PROJECT_ROOT/deploy.sh"; then
  printf 'deploy.sh still publishes /join\n' >&2
  exit 1
fi
