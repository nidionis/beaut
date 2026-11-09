#!/usr/bin/env bash
# server.sh — build and run the C HTTP relay on loopback with isolated state.
# No root, no external network: one local process per test server.

TESTS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$TESTS_LIB_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
TESTS_BUILD_DIRECTORY="${TESTS_BUILD_DIRECTORY:-$TESTS_DIR/.build}"

server_binary_path() {
  printf '%s/http-server' "$TESTS_BUILD_DIRECTORY"
}

server_build_relay() {
  local source_file="$PROJECT_ROOT/scripts/http_server.c"
  local binary
  binary="$(server_binary_path)"
  mkdir -p -- "$TESTS_BUILD_DIRECTORY"
  if [[ ! -x "$binary" || "$source_file" -nt "$binary" ]]; then
    gcc -O2 -Wall -Wextra -o "$binary" "$source_file"
  fi
  printf '%s' "$binary"
}

server_port_is_free() {
  local port="$1"
  ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null
}

server_pick_free_port() {
  local port=18080 attempt
  for attempt in {1..200}; do
    if server_port_is_free "$port"; then
      printf '%s' "$port"
      return 0
    fi
    port=$((port + 1))
  done
  return 1
}

server_start() {
  local published_root="$1" state_directory="$2" binary attempt
  SERVER_PUBLISHED_ROOT="$published_root"
  SERVER_STATE_DIRECTORY="$state_directory"
  SERVER_PORT="${SERVER_PORT:-$(server_pick_free_port)}"
  SERVER_URL="http://127.0.0.1:$SERVER_PORT"
  SERVER_LOG="$state_directory/server.log"
  SERVER_PID_FILE="$state_directory/server.pid"

  mkdir -p -- "$published_root" "$state_directory"
  export STATE_DIR="$state_directory"
  export PUBLISHED_ROOT="$published_root"
  export NOT_FOUND_BODY="${NOT_FOUND_BODY:-404}"
  export LOG_LEVEL="${LOG_LEVEL:-error}"

  binary="$(server_build_relay)"
  "$binary" "$SERVER_PORT" "$PROJECT_ROOT/scripts/http_handler.sh" \
    > "$SERVER_LOG" 2>&1 &
  SERVER_PID=$!
  printf '%s\n' "$SERVER_PID" > "$SERVER_PID_FILE"

  for attempt in {1..100}; do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      printf 'server exited before becoming ready; log follows:\n' >&2
      cat "$SERVER_LOG" >&2 || true
      return 1
    fi
    if (exec 3<>"/dev/tcp/127.0.0.1/$SERVER_PORT") 2>/dev/null; then
      return 0
    fi
    sleep 0.05
  done

  printf 'server did not become ready on %s; log follows:\n' "$SERVER_URL" >&2
  cat "$SERVER_LOG" >&2 || true
  return 1
}

server_stop() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  SERVER_PID=""
}

# http_capture <response_file> <curl arguments...>: sets HTTP_STATUS,
# HTTP_CONTENT_TYPE, HTTP_LOCATION and HTTP_BODY.
http_capture() {
  local response_file="$1"; shift
  local metadata headers_file
  headers_file="$(mktemp)"
  metadata="$(curl -s -D "$headers_file" -o "$response_file" -w '%{http_code}\n%{content_type}' "$@")"
  HTTP_STATUS="${metadata%%$'\n'*}"
  HTTP_CONTENT_TYPE="${metadata#*$'\n'}"
  HTTP_LOCATION="$(awk 'tolower($1) == "location:" { print $2 }' "$headers_file" | tr -d '\r' | tail -n 1)"
  HTTP_BODY="$(cat "$response_file")"
  rm -f -- "$response_file" "$headers_file"
}

# http_get <path>: sets HTTP_STATUS, HTTP_CONTENT_TYPE and HTTP_BODY.
http_get() {
  local path="$1" response_file
  response_file="$(mktemp)"
  http_capture "$response_file" "$SERVER_URL$path"
}

# http_get_path_as_is <path>: keeps `..` in the request (traversal tests).
http_get_path_as_is() {
  local path="$1" response_file
  response_file="$(mktemp)"
  http_capture "$response_file" --path-as-is "$SERVER_URL$path"
}

# http_post <path> <body>: sets HTTP_STATUS, HTTP_CONTENT_TYPE and HTTP_BODY.
http_post() {
  local path="$1" body="$2" response_file
  response_file="$(mktemp)"
  http_capture "$response_file" \
    -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
    --data "$body" "$SERVER_URL$path"
}

# http_post_fields <path> <key=value>...: URL-encodes every field (needed for
# WireGuard public keys containing '+', '/' and '=').
http_post_fields() {
  local path="$1"; shift
  local response_file field
  local -a curl_fields=()
  for field in "$@"; do
    curl_fields+=(--data-urlencode "$field")
  done
  response_file="$(mktemp)"
  http_capture "$response_file" "${curl_fields[@]}" "$SERVER_URL$path"
}
