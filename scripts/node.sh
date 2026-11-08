#!/usr/bin/env bash
# node.sh — node-side script (run with: curl .../node | sh).
# Claims a task, executes it locally, reports the result.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/core.sh"
. "$SCRIPT_DIR/lib/http.sh"

SERVER_HOST="${1:-${SERVER_HOST:-127.0.0.1}}"
HTTP_PORT="${HTTP_PORT:-8080}"

# 1. Claim a fresh token
http_request GET /work
token="$http_body"
if [[ "$http_status" != "200" ]]; then
  echo "failure: cannot claim a token (HTTP $http_status)" >&2
  exit 1
fi
if [[ -z "$token" ]]; then
  echo "failure: no token received" >&2
  exit 1
fi
echo "token received: $token"

# 2. Fetch the command bound to the token
http_request GET "/work/$token"
task_command="$http_body"
if [[ "$http_status" != "200" || -z "$task_command" ]]; then
  echo "failure: command unavailable for token $token (HTTP $http_status)" >&2
  exit 1
fi
echo "command: $task_command"

# 3. Execute locally
output="$(bash -c "$task_command" 2>&1)"
exit_code=$?

# 4. Report the result
http_request POST "/done/$token" "output=$output"
if [[ "$http_status" != "200" ]]; then
  echo "failure: could not report result (HTTP $http_status)" >&2
fi
echo "result sent to /done/$token (exit: $exit_code)"

exit "$exit_code"
