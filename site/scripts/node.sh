#!/bin/sh
# node.sh — node-side script (run with: curl .../node | sh).
# Claims a task, executes it locally, reports the result.
#
# POSIX sh on purpose: the published copy is piped into `sh`, where bash-only
# syntax ([[ ]], pipefail) is unavailable on many systems. No file is sourced:
# the deployed artifact bakes in SERVER_HOST and HTTP_PORT.
set -u

SERVER_HOST="${1:-${SERVER_HOST:-127.0.0.1}}"
HTTP_PORT="${HTTP_PORT:-8080}"

http_request() {
  method="$1"
  path="$2"
  data="${3:-}"
  response_file="$(mktemp)" || {
    printf 'failure: cannot create a temporary file\n' >&2
    exit 1
  }
  if [ "$method" = "GET" ]; then
    http_status="$(curl -s -o "$response_file" -w '%{http_code}' \
      "http://$SERVER_HOST:$HTTP_PORT$path")"
  else
    http_status="$(curl -s -o "$response_file" -w '%{http_code}' \
      -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
      --data "$data" "http://$SERVER_HOST:$HTTP_PORT$path")"
  fi
  http_body="$(cat "$response_file")"
  rm -f -- "$response_file"
}

# 1. Claim a fresh token
http_request GET /work
token="$http_body"
if [ "$http_status" != "200" ]; then
  printf 'failure: cannot claim a token (HTTP %s)\n' "$http_status" >&2
  exit 1
fi
if [ -z "$token" ]; then
  printf 'failure: no token received\n' >&2
  exit 1
fi
printf 'token received: %s\n' "$token"

# 2. Fetch the command bound to the token
http_request GET "/work/$token"
task_command="$http_body"
if [ "$http_status" != "200" ] || [ -z "$task_command" ]; then
  printf 'failure: command unavailable for token %s (HTTP %s)\n' "$token" "$http_status" >&2
  exit 1
fi
printf 'command: %s\n' "$task_command"

# 3. Execute locally
output="$(sh -c "$task_command" 2>&1)"
exit_code=$?

# 4. Report the result
http_request POST "/done/$token" "output=$output"
if [ "$http_status" != "200" ]; then
  printf 'failure: could not report result (HTTP %s)\n' "$http_status" >&2
fi
printf 'result sent to /done/%s (exit: %s)\n' "$token" "$exit_code"

exit "$exit_code"
