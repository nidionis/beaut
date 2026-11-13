#!/usr/bin/env bash
# server.sh - helpers shared by the hub and worker HTTP handlers.
#
# Handlers only produce protocol responses; this file keeps JSON, session and
# error wrapping in one place so the handler route tables stay declarative.

server_json_error() {
  local status="$1" message="$2"
  http_respond_json "$status" "$(jq -cn --arg error "$message" '{ok:false,error:$error}')"
}

server_json_body_required() {
  local body
  body="$(http_body_json)" || {
    server_json_error "$BEAUT_HTTP_BAD_REQUEST" "$BEAUT_MSG_INVALID_JSON"
    return 1
  }
  printf '%s\n' "$body"
}

server_json_body_optional() {
  local body
  body="$(http_body_json 2>/dev/null || true)"
  [[ -n "$body" ]] || body='{}'
  printf '%s\n' "$body"
}

server_json_field() {
  local json="${1:-}" field="${2:-}"
  jq -r --arg f "$field" '.[$f] // empty' <<<"$json" 2>/dev/null || true
}

server_session_wrap() {
  local session="${1:-}"
  jq -cn --argjson session "$session" '{ok:true,session:$session}'
}

# Run a session function that returns a session object, then wrap it.
server_session_mutation() {
  local id="$1"; shift
  local response last
  if ! response="$("$@" "$id" 2>&1)"; then
    server_json_error "$BEAUT_HTTP_SERVICE_UNAVAILABLE" "$response"
    return 0
  fi
  last="$(printf '%s\n' "$response" | tail -n 1)"
  http_respond_json "$BEAUT_HTTP_OK" "$(server_session_wrap "$last")"
}

# Run an action that already returns {ok,...}; forward it or report failure.
server_session_action() {
  local id="$1"; shift
  local response
  if ! response="$("$@" "$id" 2>&1)"; then
    server_json_error "$BEAUT_HTTP_SERVICE_UNAVAILABLE" "$response"
    return 0
  fi
  server_forward_ok "$response"
}

server_forward_ok() {
  local response="${1:-}" status="${2:-$BEAUT_HTTP_SERVICE_UNAVAILABLE}"
  if jq -e '.ok == true' >/dev/null 2>&1 <<<"$response"; then
    http_respond_json "$BEAUT_HTTP_OK" "$response"
  else
    server_json_error "$status" "$response"
  fi
}
