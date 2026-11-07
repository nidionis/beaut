#!/usr/bin/env bash
# node.sh — node-side script (run with: curl .../node | sh).
# Claims a task, executes it locally, reports the result.
set -uo pipefail

SERVER_HOST="${1:-${SERVER_HOST:-127.0.0.1}}"
HTTP_PORT="${HTTP_PORT:-8080}"
BASE_URL="http://$SERVER_HOST:$HTTP_PORT"

# 1. Claim a fresh token
token="$(curl -s "$BASE_URL/work")"
if [[ -z "$token" ]]; then
  echo "failure: no token received" >&2
  exit 1
fi
echo "token received: $token"

# 2. Fetch the command bound to the token
task_command="$(curl -s "$BASE_URL/work/$token")"
if [[ -z "$task_command" || "$task_command" == *"error"* || "$task_command" == *"expired"* ]]; then
  echo "failure: command unavailable for token $token" >&2
  echo "$task_command" >&2
  exit 1
fi
echo "command: $task_command"

# 3. Execute locally
output="$(bash -c "$task_command" 2>&1)"
exit_code=$?

# 4. Report the result
curl -s -X POST "$BASE_URL/done/$token" --data-urlencode "output=$output" >/dev/null
echo "result sent to /done/$token (exit: $exit_code)"

exit "$exit_code"
