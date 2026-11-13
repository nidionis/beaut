#!/usr/bin/env bash
# upstream.sh - tiny read-only HTTP upstream used by integration tests.
set -u
request_line=""
IFS= read -r request_line || exit 1
request_line="${request_line%$'\r'}"
method="${request_line%% *}"
rest="${request_line#* }"
target="${rest%% *}"
while IFS= read -r header; do
  header="${header%$'\r'}"
  [[ -z "$header" ]] && break
done
body="hello ${method} ${target:-/} from upstream"
printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
  "${#body}" "$body"
