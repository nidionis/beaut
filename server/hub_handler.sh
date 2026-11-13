#!/usr/bin/env bash
# hub_handler.sh - one HTTP connection on the hub.
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

beaut_load_config
BEAUT_ROLE=hub
BEAUT_NODE_NAME="$BEAUT_HUB_NAME"
export BEAUT_ROLE BEAUT_NODE_NAME
beaut_state_init
store_init
routes_seed >/dev/null 2>&1 || true

cleanup() {
  rm -f -- "$HTTP_BODY_FILE"
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

hub_health() {
  http_respond "$BEAUT_HTTP_OK" text/plain "ok"
}

hub_info() {
  local workers packages sessions routes body
  workers="$(worker_rows | wc -l | tr -d ' ')"
  packages="$(store_stats)"
  sessions="$(session_list | jq 'length')"
  routes="$(routes_list | wc -l | tr -d ' ')"
  body="$(jq -cn \
    --arg name "$BEAUT_HUB_NAME" \
    --arg version "$BEAUT_VERSION" \
    --arg hub_url "$BEAUT_HUB_URL" \
    --arg public_url "$BEAUT_PUBLIC_URL" \
    --arg domain "$BEAUT_HUB_DOMAIN" \
    --argjson workers "$workers" \
    --argjson packages "$packages" \
    --argjson sessions "$sessions" \
    --argjson routes "$routes" \
    '{ok:true,name:$name,version:$version,role:"hub",
      hub_url:$hub_url,public_url:$public_url,domain:$domain,
      workers:$workers,store:$packages,sessions:$sessions,routes:$routes}')"
  http_respond_json "$BEAUT_HTTP_OK" "$body"
}

hub_workers_list() {
  http_respond_json "$BEAUT_HTTP_OK" "$(workers_json)"
}

hub_routes_list() {
  http_respond_json "$BEAUT_HTTP_OK" "$(routes_json)"
}

hub_route_find() {
  local wanted_host wanted_path row
  wanted_host="$(http_query_param host || true)"
  wanted_path="$(http_query_param path || true)"
  [[ -n "$wanted_path" ]] || wanted_path="/"
  row="$(route_find "$wanted_host" "$wanted_path" 2>/dev/null || true)"
  if [[ -z "$row" ]]; then
    server_json_error "$BEAUT_HTTP_NOT_FOUND" "no route"
    return 0
  fi
  http_respond_json "$BEAUT_HTTP_OK" "$(route_row_json "$row")"
}

hub_packages_list() {
  http_respond_json "$BEAUT_HTTP_OK" "$(store_list)"
}

hub_sessions_list() {
  http_respond_json "$BEAUT_HTTP_OK" "$(session_list)"
}

hub_store_stats() {
  http_respond_json "$BEAUT_HTTP_OK" "$(store_stats)"
}

# ---- write endpoints --------------------------------------------------------

hub_route_add() {
  local body name host path worker port mode hub listen
  body="$(server_json_body_required)" || return 0
  name="$(server_json_field "$body" name)"
  host="$(server_json_field "$body" host)"
  path="$(server_json_field "$body" path)"
  worker="$(server_json_field "$body" worker)"
  port="$(server_json_field "$body" port)"
  mode="$(server_json_field "$body" mode)"
  hub="$(server_json_field "$body" hub)"
  listen="$(server_json_field "$body" listen_port)"
  [[ -n "$path" ]] || path="/"
  [[ -n "$mode" ]] || mode="$BEAUT_ROUTE_MODE_DEFAULT"
  [[ -n "$hub" ]] || hub="$BEAUT_HUB_NAME"
  if ! route_add "$name" "$host" "$path" "$worker" "$port" "$mode" "$hub" "$listen" 1; then
    server_json_error "$BEAUT_HTTP_BAD_REQUEST" "invalid route"
    return 0
  fi
  http_respond_json "$BEAUT_HTTP_OK" "$(routes_json)"
}

hub_package_upload() {
  local name kind copies allow_degraded id manifest copyn degraded
  name="$(http_query_param name || true)"
  kind="$(http_query_param kind || true)"
  copies="$(http_query_param copies || true)"
  allow_degraded="$(http_query_param allow_degraded || true)"
  [[ -n "$name" ]] || name="package-$(beaut_now)"
  [[ -n "$kind" ]] || kind="$BEAUT_PACKAGE_KIND_DEFAULT"
  [[ -n "$copies" ]] || copies="$BEAUT_MIN_COPIES"
  if ! store_package_kind_valid "$kind"; then
    server_json_error "$BEAUT_HTTP_UNSUPPORTED_MEDIA_TYPE" "unsupported package kind"
    return 0
  fi
  [[ "$copies" =~ ^[0-9]+$ ]] || copies="$BEAUT_MIN_COPIES"
  if [[ ! -s "${HTTP_BODY_FILE:-}" ]]; then
    server_json_error "$BEAUT_HTTP_BAD_REQUEST" "empty package body"
    return 0
  fi
  id="$(store_add_file "$HTTP_BODY_FILE" "$name" "$kind" "$copies" 2>/dev/null)" || {
    server_json_error "$BEAUT_HTTP_INTERNAL_SERVER_ERROR" "package store failed"
    return 0
  }
  store_replicate "$id" >/dev/null 2>&1 || true
  manifest="$(store_manifest "$id")"
  copyn="$(jq -r '.copies | length' <<<"$manifest")"
  degraded="$(jq -r '.degraded' <<<"$manifest")"
  if [[ "$degraded" == "true" && "$BEAUT_STRICT_COPIES" == "1" \
        && "$allow_degraded" != "1" ]]; then
    http_respond_json "$BEAUT_HTTP_SERVICE_UNAVAILABLE" \
      "$(jq -cn --argjson manifest "$manifest" --argjson copies "$copyn" \
        '{ok:false,error:"fewer copies than required",manifest:$manifest,copies:$copies}')"
  else
    http_respond_json "$BEAUT_HTTP_CREATED" \
      "$(jq -cn --argjson manifest "$manifest" --argjson copies "$copyn" \
        '{ok:true,manifest:$manifest,copies:$copies}')"
  fi
}

hub_store_scrub() {
  local scrub ok
  scrub="$(store_scrub_json 2>/dev/null || true)"
  [[ -n "$scrub" ]] || scrub='{"ok":false,"results":[]}'
  ok="$(jq -r '.ok // false' <<<"$scrub" 2>/dev/null || printf 'false')"
  if [[ "$ok" == "true" ]]; then
    http_respond_json "$BEAUT_HTTP_OK" "$scrub"
  else
    http_respond_json "$BEAUT_HTTP_SERVICE_UNAVAILABLE" "$scrub"
  fi
}

hub_session_create() {
  local body name image worker port protocol command_json response
  body="$(server_json_body_required)" || return 0
  name="$(server_json_field "$body" name)"
  image="$(server_json_field "$body" image)"
  worker="$(server_json_field "$body" worker)"
  port="$(server_json_field "$body" container_port)"
  protocol="$(server_json_field "$body" protocol)"
  command_json="$(jq -c '.command // []' <<<"$body")"
  [[ -n "$port" ]] || port="$BEAUT_SESSION_PORT"
  [[ -n "$protocol" ]] || protocol="$BEAUT_SESSION_PROTOCOL"
  if [[ -z "$name" || -z "$image" ]]; then
    server_json_error "$BEAUT_HTTP_BAD_REQUEST" "name and image are required"
    return 0
  fi
  response="$(session_create "$name" "$image" "$worker" "$port" "$protocol" "$command_json" 2>&1)" || {
    server_json_error "$BEAUT_HTTP_SERVICE_UNAVAILABLE" "$response"
    return 0
  }
  http_respond_json "$BEAUT_HTTP_CREATED" \
    "$(server_session_wrap "$(printf '%s\n' "$response" | tail -n 1)")"
}

# ---- package subresources ---------------------------------------------------

hub_package_replicate() {
  local id manifest
  id="$(http_param id)"
  if ! store_manifest_exists "$id"; then
    server_json_error "$BEAUT_HTTP_NOT_FOUND" "$BEAUT_MSG_PACKAGE_NOT_FOUND"
    return 0
  fi
  if store_replicate "$id" >/dev/null 2>&1; then
    http_respond_json "$BEAUT_HTTP_OK" "$(store_manifest "$id")"
  else
    server_json_error "$BEAUT_HTTP_SERVICE_UNAVAILABLE" "replication incomplete"
  fi
}

hub_package_verify() {
  local id full
  id="$(http_param id)"
  full="$(http_query_param full || true)"
  [[ "$full" == "1" ]] || full=0
  if store_verify "$id" "$full"; then
    http_respond_json "$BEAUT_HTTP_OK" \
      "$(jq -cn --arg id "$id" --argjson full "$full" '{ok:true,id:$id,full:($full == 1)}')"
  else
    server_json_error "$BEAUT_HTTP_SERVICE_UNAVAILABLE" "verification failed"
  fi
}

hub_package_download() {
  local id manifest
  id="$(http_param id)"
  if ! store_manifest_complete "$id"; then
    store_fetch "$id" >/dev/null 2>&1 || true
  fi
  manifest="$(store_manifest "$id" 2>/dev/null)" || {
    server_json_error "$BEAUT_HTTP_NOT_FOUND" "$BEAUT_MSG_PACKAGE_NOT_FOUND"
    return 0
  }
  if ! http_stream_package "$manifest" 2>/dev/null; then
    server_json_error "$BEAUT_HTTP_INTERNAL_SERVER_ERROR" "package read failed"
  fi
}

hub_package_show() {
  local id manifest
  id="$(http_param id)"
  manifest="$(store_manifest "$id" 2>/dev/null)" || {
    store_fetch "$id" >/dev/null 2>&1 || true
    manifest="$(store_manifest "$id" 2>/dev/null)" || {
      server_json_error "$BEAUT_HTTP_NOT_FOUND" "$BEAUT_MSG_PACKAGE_NOT_FOUND"
      return 0
    }
  }
  http_respond_json "$BEAUT_HTTP_OK" "$manifest"
}

hub_route_delete() {
  route_remove "$(http_param name)"
  http_respond_json "$BEAUT_HTTP_OK" '{"ok":true}'
}

# ---- session subresources ---------------------------------------------------

hub_session_show() {
  local id session
  id="$(http_param id)"
  session="$(session_get "$id" 2>/dev/null)" || {
    server_json_error "$BEAUT_HTTP_NOT_FOUND" "$BEAUT_MSG_SESSION_NOT_FOUND"
    return 0
  }
  http_respond_json "$BEAUT_HTTP_OK" "$session"
}

hub_session_delete() {
  session_remove "$(http_param id)" >/dev/null 2>&1 || true
  http_respond_json "$BEAUT_HTTP_OK" '{"ok":true}'
}

hub_session_snapshot() {
  server_session_action "$(http_param id)" session_snapshot
}

hub_session_status() {
  server_session_action "$(http_param id)" session_live_status
}

hub_session_restore() {
  local id body worker response
  id="$(http_param id)"
  body="$(server_json_body_optional)"
  worker="$(server_json_field "$body" worker)"
  if ! response="$(session_restore "$id" "$worker" 2>&1)"; then
    server_json_error "$BEAUT_HTTP_SERVICE_UNAVAILABLE" "$response"
    return 0
  fi
  http_respond_json "$BEAUT_HTTP_OK" \
    "$(server_session_wrap "$(printf '%s\n' "$response" | tail -n 1)")"
}

hub_session_move() {
  local id body worker response
  id="$(http_param id)"
  body="$(server_json_body_optional)"
  worker="$(server_json_field "$body" worker)"
  if [[ -z "$worker" ]]; then
    server_json_error "$BEAUT_HTTP_BAD_REQUEST" "worker is required"
    return 0
  fi
  if ! response="$(session_move "$id" "$worker" 2>&1)"; then
    server_json_error "$BEAUT_HTTP_SERVICE_UNAVAILABLE" "$response"
    return 0
  fi
  http_respond_json "$BEAUT_HTTP_OK" \
    "$(server_session_wrap "$(printf '%s\n' "$response" | tail -n 1)")"
}

hub_session_exec() {
  local id body command_json response
  id="$(http_param id)"
  body="$(server_json_body_optional)"
  command_json="$(jq -c '.command // []' <<<"$body" 2>/dev/null || printf '[]')"
  if ! response="$(session_exec "$id" "$command_json" 2>&1)"; then
    server_json_error "$BEAUT_HTTP_SERVICE_UNAVAILABLE" "$response"
    return 0
  fi
  server_forward_ok "$response"
}

# ---- session path proxy: /s/<id>/... ---------------------------------------

hub_session_proxy() {
  local rest id remainder session host port target
  rest="${HTTP_PATH_ABS#/s/}"
  id="${rest%%/*}"
  if [[ "$rest" == */* ]]; then
    remainder="/${rest#*/}"
  else
    remainder="/"
  fi
  id="$(http_url_decode "$id")"
  session="$(session_get "$id" 2>/dev/null)" || {
    server_json_error "$BEAUT_HTTP_NOT_FOUND" "$BEAUT_MSG_SESSION_NOT_FOUND"
    return 0
  }
  if [[ "$(jq -r '.status // ""' <<<"$session")" != "running" ]]; then
    server_json_error "$BEAUT_HTTP_SERVICE_UNAVAILABLE" "session is not running"
    return 0
  fi
  host="$(jq -r '.worker_host // ""' <<<"$session")"
  port="$(jq -r '.host_port // 0' <<<"$session")"
  if [[ -z "$host" || ! "$port" =~ ^[0-9]+$ ]]; then
    server_json_error "$BEAUT_HTTP_SERVICE_UNAVAILABLE" "session has no route"
    return 0
  fi
  target="http://${host}:${port}${remainder}"
  [[ -n "$HTTP_QUERY" ]] && target="${target}?${HTTP_QUERY}"
  http_proxy_http "$target"
}

# ---- route table ------------------------------------------------------------

http_route GET /health hub_health
http_route GET /info hub_info
http_route GET /workers hub_workers_list
http_route GET /routes hub_routes_list
http_route POST /routes hub_route_add
http_route GET /routes/find hub_route_find
http_route DELETE /routes/:name hub_route_delete
http_route GET /packages hub_packages_list
http_route PUT /packages hub_package_upload
http_route GET /packages/:id hub_package_show
http_route GET /packages/:id/download hub_package_download
http_route POST /packages/:id/replicate hub_package_replicate
http_route POST /packages/:id/verify hub_package_verify
http_route GET /store/stats hub_store_stats
http_route POST /store/scrub hub_store_scrub
http_route GET /sessions hub_sessions_list
http_route POST /sessions hub_session_create
http_route GET /sessions/:id hub_session_show
http_route DELETE /sessions/:id hub_session_delete
http_route POST /sessions/:id/stop hub_session_mutation_wrapper session_stop
http_route POST /sessions/:id/start hub_session_mutation_wrapper session_start
http_route POST /sessions/:id/snapshot hub_session_snapshot
http_route POST /sessions/:id/restore hub_session_restore
http_route POST /sessions/:id/move hub_session_move
http_route POST /sessions/:id/exec hub_session_exec
http_route POST /sessions/:id/status hub_session_status
http_route GET /sessions/:id/status hub_session_status
http_route "POST DELETE" /sessions/:id/rm hub_session_delete
http_route ANY /s/:id hub_session_proxy
http_route ANY /s/:id/* hub_session_proxy

# The route table supplies the function name for stop/start, so the dispatcher
# can call a single wrapper without a per-action case statement.
hub_session_mutation_wrapper() {
  server_session_mutation "$(http_param id)" "${1:-}"
}

if http_dispatch; then
  exit 0
fi

# ---- configured route proxy ------------------------------------------------
route_row="$(route_find "${HTTP_HEADERS[host]:-}" "$HTTP_PATH_ABS" 2>/dev/null || true)"
if [[ -n "$route_row" ]]; then
  target_url="$(route_proxy_url "$route_row" "$HTTP_PATH_ABS" 2>/dev/null || true)"
  if [[ -n "$target_url" ]]; then
    http_proxy_http "$target_url"
    exit 0
  fi
fi

# ---- static dashboard ------------------------------------------------------
if [[ "$HTTP_PATH_ABS" == "/" ]]; then
  http_serve_static "$BEAUT_WWW_DIR" index.html
  exit 0
fi
if [[ "$HTTP_METHOD" == "GET" || "$HTTP_METHOD" == "HEAD" ]]; then
  http_serve_static "$BEAUT_WWW_DIR" "$HTTP_PATH_RAW"
  exit 0
fi

http_respond_error "$BEAUT_HTTP_NOT_FOUND" "$BEAUT_MSG_NOT_FOUND"
