#!/usr/bin/env bash
# worker_handler.sh - one HTTP connection on a worker.
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEAUT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$BEAUT_ROOT/lib/common.sh"
. "$BEAUT_ROOT/lib/config.sh"
. "$BEAUT_ROOT/lib/http.sh"
. "$BEAUT_ROOT/lib/dispatch.sh"
. "$BEAUT_ROOT/lib/server.sh"
. "$BEAUT_ROOT/lib/store.sh"
. "$BEAUT_ROOT/lib/workers.sh"
. "$BEAUT_ROOT/lib/routes.sh"
. "$BEAUT_ROOT/lib/sessions.sh"
. "$BEAUT_ROOT/lib/docker.sh"

beaut_load_config
BEAUT_ROLE=worker
BEAUT_NODE_NAME="$BEAUT_WORKER_NAME"
export BEAUT_ROLE BEAUT_NODE_NAME
beaut_state_init
store_init

cleanup() {
  [[ -n "${HTTP_BODY_FILE:-}" && -f "${HTTP_BODY_FILE:-}" ]] && rm -f -- "$HTTP_BODY_FILE"
}
trap cleanup EXIT

http_parse_request
parse_status=$?
if (( parse_status == 2 )); then
  http_respond_error "$BEAUT_HTTP_PAYLOAD_TOO_LARGE" "$BEAUT_MSG_REQUEST_TOO_LARGE"
  exit 0
elif (( parse_status != 0 )); then
  http_respond_error "$BEAUT_HTTP_BAD_REQUEST" "$BEAUT_MSG_BAD_REQUEST"
  exit 0
fi

HTTP_METHOD="${HTTP_METHOD^^}"
HTTP_PATH_RAW="$HTTP_PATH"
HTTP_PATH_ABS="/${HTTP_PATH_RAW}"
[[ -z "$HTTP_PATH_RAW" ]] && HTTP_PATH_ABS="/"

# ---- read endpoints ---------------------------------------------------------

worker_health() {
  http_respond "$BEAUT_HTTP_OK" text/plain "ok"
}

worker_info() {
  http_respond_json "$BEAUT_HTTP_OK" "$(worker_resources_json)"
}

worker_sessions_list() {
  http_respond_json "$BEAUT_HTTP_OK" "$(docker_session_list_local)"
}

worker_store_packages() {
  http_respond_json "$BEAUT_HTTP_OK" "$(store_list)"
}

worker_store_stats() {
  http_respond_json "$BEAUT_HTTP_OK" "$(store_stats)"
}

# ---- session lifecycle ------------------------------------------------------

worker_session_run() {
  local response
  if [[ ! -s "${HTTP_BODY_FILE:-}" ]]; then
    server_json_error "$BEAUT_HTTP_BAD_REQUEST" "missing session spec"
    return 0
  fi
  response="$(docker_session_run_file "$HTTP_BODY_FILE" 0 2>&1)" || true
  if jq -e '.ok == true' >/dev/null 2>&1 <<<"$response"; then
    http_respond_json "$BEAUT_HTTP_OK" "$response"
  else
    server_json_error "$BEAUT_HTTP_BAD_REQUEST" "$response"
  fi
}

worker_session_get() {
  local id record
  id="$(http_param id)"
  record="$(docker_local_session_get "$id" 2>/dev/null)" || {
    server_json_error "$BEAUT_HTTP_NOT_FOUND" "$BEAUT_MSG_SESSION_NOT_FOUND"
    return 0
  }
  http_respond_json "$BEAUT_HTTP_OK" "$record"
}

worker_session_action() {
  server_session_action "$(http_param id)" "${1:-}"
}

worker_session_restore() {
  local id body snapshot image container_port protocol command_json name response
  id="$(http_param id)"
  body="$(server_json_body_optional)"
  snapshot="$(server_json_field "$body" snapshot)"
  image="$(server_json_field "$body" image)"
  container_port="$(server_json_field "$body" container_port)"
  protocol="$(server_json_field "$body" protocol)"
  command_json="$(jq -c '.command // []' <<<"$body" 2>/dev/null || printf '[]')"
  name="$(server_json_field "$body" name)"
  [[ -n "$name" ]] || name="$id"
  [[ -n "$protocol" ]] || protocol="$BEAUT_SESSION_PROTOCOL"
  response="$(docker_session_restore "$id" "$snapshot" "$image" "$container_port" \
    "$protocol" "$command_json" "$name" 2>&1)" || true
  server_forward_ok "$response"
}

worker_session_exec() {
  local id body command_json response
  id="$(http_param id)"
  body="$(server_json_body_optional)"
  command_json="$(jq -c '.command // []' <<<"$body" 2>/dev/null || printf '[]')"
  response="$(docker_session_exec "$id" "$command_json" 2>&1)" || true
  server_forward_ok "$response"
}

# ---- store endpoints --------------------------------------------------------

worker_store_bundle_put() {
  local id
  if [[ ! -s "${HTTP_BODY_FILE:-}" ]]; then
    server_json_error "$BEAUT_HTTP_BAD_REQUEST" "empty bundle"
    return 0
  fi
  id="$(store_receive_bundle "$HTTP_BODY_FILE" 2>/dev/null)" || {
    server_json_error "$BEAUT_HTTP_BAD_REQUEST" "invalid bundle"
    return 0
  }
  http_respond_json "$BEAUT_HTTP_OK" "$(jq -cn --arg id "$id" '{ok:true,id:$id}')"
}

worker_package_bundle() {
  local id manifest tmp
  id="$(http_param id)"
  manifest="$(store_manifest "$id" 2>/dev/null)" || {
    server_json_error "$BEAUT_HTTP_NOT_FOUND" "$BEAUT_MSG_PACKAGE_NOT_FOUND"
    return 0
  }
  tmp="$(mktemp "${BEAUT_STORE_DIR}/tmp/serve.XXXXXX")" || {
    server_json_error "$BEAUT_HTTP_INTERNAL_SERVER_ERROR" "cannot create bundle"
    return 0
  }
  if store_bundle "$id" "$tmp" >/dev/null 2>&1; then
    http_stream_file "$tmp" 'application/gzip'
  else
    server_json_error "$BEAUT_HTTP_INTERNAL_SERVER_ERROR" "cannot create bundle"
  fi
  rm -f -- "$tmp"
}

worker_package_download() {
  local id manifest
  id="$(http_param id)"
  manifest="$(store_manifest "$id" 2>/dev/null)" || {
    server_json_error "$BEAUT_HTTP_NOT_FOUND" "$BEAUT_MSG_PACKAGE_NOT_FOUND"
    return 0
  }
  if ! http_stream_package "$manifest"; then
    server_json_error "$BEAUT_HTTP_INTERNAL_SERVER_ERROR" "package read failed"
  fi
}

worker_package_show() {
  local id manifest
  id="$(http_param id)"
  manifest="$(store_manifest "$id" 2>/dev/null)" || {
    server_json_error "$BEAUT_HTTP_NOT_FOUND" "$BEAUT_MSG_PACKAGE_NOT_FOUND"
    return 0
  }
  http_respond_json "$BEAUT_HTTP_OK" "$manifest"
}

# ---- route table ------------------------------------------------------------

http_route GET /health worker_health
http_route GET /info worker_info
http_route GET /sessions worker_sessions_list
http_route GET /store/packages worker_store_packages
http_route GET /store/stats worker_store_stats
http_route POST /sessions/run worker_session_run
http_route PUT /store/bundle worker_store_bundle_put
http_route GET /store/packages/:id/bundle worker_package_bundle
http_route GET /store/packages/:id/download worker_package_download
http_route GET /store/packages/:id worker_package_show
http_route GET /sessions/:id worker_session_get
http_route "GET POST" /sessions/:id/status worker_session_action docker_session_status
http_route POST /sessions/:id/stop worker_session_action docker_session_stop
http_route POST /sessions/:id/start worker_session_action docker_session_start
http_route POST /sessions/:id/snapshot worker_session_action docker_session_snapshot
http_route POST /sessions/:id/restore worker_session_restore
http_route POST /sessions/:id/exec worker_session_exec
http_route "POST DELETE" /sessions/:id/rm worker_session_action docker_session_rm

if http_dispatch; then
  exit 0
fi

http_respond_error "$BEAUT_HTTP_NOT_FOUND" "$BEAUT_MSG_NOT_FOUND"
