#!/usr/bin/env bash
# cli.sh - command layer for the beaut CLI.
#
# beaut.sh only resolves its own path and sources the libraries; this file owns
# argument parsing, API-first command dispatch and local fallback behaviour.
# Hub addresses always come from beaut.conf (BEAUT_HUB_URL), never from a
# literal in the command code.

declare -A BEAUT_OPT=()
declare -A BEAUT_OPT_MULTI=()
BEAUT_ARGS=()

# beaut_parse_options 'name,kind,copies,flag!,repeat+' -- ARGS...
#
#   name      option that takes a value
#   flag!     boolean flag (presence only)
#   repeat+   option that may be repeated; values are newline-separated in
#             BEAUT_OPT_MULTI[name]
#
# Positional arguments are collected in BEAUT_ARGS.  Unknown options and
# missing values return status 2.
beaut_parse_options() {
  local spec="${1:-}"; shift || true
  [[ "${1:-}" == "--" ]] && shift
  BEAUT_OPT=()
  BEAUT_OPT_MULTI=()
  BEAUT_ARGS=()
  local -A wants_value=() is_flag=() is_repeat=()
  local item key value
  local -a items=()
  IFS=',' read -r -a items <<<"$spec"
  for item in "${items[@]}"; do
    [[ -n "$item" ]] || continue
    case "$item" in
      *!) is_flag["${item%!}"]=1 ;;
      *+) is_repeat["${item%+}"]=1 ;;
      *) wants_value["$item"]=1 ;;
    esac
  done
  while (( $# )); do
    case "$1" in
      --)
        shift
        BEAUT_ARGS+=("$@")
        break
        ;;
      --*)
        key="${1#--}"
        shift
        value=""
        if [[ "$key" == *=* ]]; then
          value="${key#*=}"
          key="${key%%=*}"
        fi
        if [[ -n "${is_flag[$key]:-}" ]]; then
          BEAUT_OPT["$key"]=1
        elif [[ -n "${is_repeat[$key]:-}" ]]; then
          if [[ -z "$value" ]]; then
            if (( $# == 0 )); then
              beaut_warn "missing value for --$key"
              return 2
            fi
            value="$1"; shift
          fi
          BEAUT_OPT_MULTI["$key"]+="${value}"$'\n'
        elif [[ -n "${wants_value[$key]:-}" ]]; then
          if [[ -z "$value" ]]; then
            if (( $# == 0 )); then
              beaut_warn "missing value for --$key"
              return 2
            fi
            value="$1"; shift
          fi
          BEAUT_OPT["$key"]="$value"
        else
          beaut_warn "unknown option: --$key"
          return 2
        fi
        ;;
      -*)
        beaut_warn "unknown option: $1"
        return 2
        ;;
      *)
        BEAUT_ARGS+=("$1")
        shift
        ;;
    esac
  done
  return 0
}

usage() {
  cat <<'EOF'
usage: beaut [--config FILE] COMMAND [ARGS]

Installation and node operation (local sudo, or key/agent SSH + SFTP + systemd):
  install hub|worker NAME|all     install files/config/units; local targets run
                                  in place, remote targets upload over SFTP;
                                  alias: deploy (bootstrap a new node once with
                                  sudo scripts/bootstrap-node.sh)
  hub serve                       run the hub HTTP server
  worker serve                    run a worker HTTP server
  router run|sync|stop            raw TCP route listeners
  status                          hub/workers/sessions/store summary
  doctor                          check dependencies and configuration
  init | config path|show|edit
  version
  help api                        HTTP endpoint reference

Docker sessions (hub HTTP API, usable from any reachable host):
  session create NAME IMAGE [--worker W] [--port N] [--protocol P] [--command CMD]...
  session ls [--json] | show ID
  session stop|start|snapshot ID
  session restore ID [--worker W]
  session move ID WORKER
  session exec ID [--] COMMAND...
  session rm ID

Packages (content-addressed, replicated to configured workers):
  package add FILE [--name N] [--kind K] [--copies N] [--allow-degraded]
  package ls [--json] | show ID
  package get ID OUT
  package replicate ID
  package verify ID [--full]
  package scrub [--json]
  package stats [--json]

Routing:
  route add NAME HOST PATH WORKER PORT [http|tcp] [HUB] [LISTEN_PORT]
  route ls [--json]
  route rm NAME
  route find HOST PATH
  route sync

Worker resources:
  worker resources [--cpus N] [--memory MB] [--disk MB] [--tags T]
                   [--max-sessions N] [--write]

Examples:
  beaut install hub
  beaut install worker w1
  beaut install all
  beaut session create demo alpine:3 --worker w1 --command sleep --command infinity
  beaut session exec s_... -- uname -a
  beaut package add image.tar --kind oci-image --copies 2
  beaut help api

Installation targets come from BEAUT_HUB_URL and BEAUT_WORKERS.  A target that
resolves to this machine is installed in place with sudo; other targets use
beaut@host with port and key from ~/.ssh/config.  On a new node run
`sudo scripts/bootstrap-node.sh` once; it creates the BEAUT_NAME account and
authorizes your SSH keys.  Remote files move over SFTP and the privileged
installer runs through sudo over SSH.

The CLI talks to BEAUT_HUB_URL over HTTP first, so package, route and Docker
session commands work remotely.  If the hub is unreachable it falls back to
local state (useful on the hub host).  Docker and package management should
use this CLI or the HTTP API, not ad-hoc commands.
EOF
}

usage_api() {
  local base="${BEAUT_HUB_URL:-<BEAUT_HUB_URL from beaut.conf>}"
  cat <<EOF
beaut HTTP API
base: $base

Read:
  GET  /health
  GET  /info
  GET  /workers
  GET  /routes                 POST /routes
  GET  /routes/find?host=H&path=P
  GET  /packages               PUT  /packages?name=N&kind=K&copies=C
                                  # add &allow_degraded=1 to accept fewer copies
  GET  /packages/ID            GET  /packages/ID/download
  POST /packages/ID/replicate
  POST /packages/ID/verify?full=1
  GET  /store/stats            POST /store/scrub
  GET  /sessions               POST /sessions
  GET  /sessions/ID            DELETE /sessions/ID
  POST /sessions/ID/stop|start|snapshot|restore|move|exec
  GET  /sessions/ID/status
  GET  /s/ID/...                  proxy to a running session

Examples (BEAUT_HUB_URL is already in your config):
  curl "\$BEAUT_HUB_URL/sessions"
  curl -X POST "\$BEAUT_HUB_URL/sessions" \\
       -H 'Content-Type: application/json' \\
       -d '{"name":"demo","image":"alpine:3","worker":"w1","container_port":8080}'
  curl -X POST "\$BEAUT_HUB_URL/sessions/ID/exec" \\
       -H 'Content-Type: application/json' -d '{"command":["uname","-a"]}'
  curl -X PUT "\$BEAUT_HUB_URL/packages?name=blob.bin&kind=data&copies=2" \\
       --data-binary @blob.bin
EOF
}

require_common() {
  beaut_require jq curl tar gzip
}

cli_local_hub() {
  BEAUT_ROLE=hub
  BEAUT_NODE_NAME="$BEAUT_HUB_NAME"
  export BEAUT_ROLE BEAUT_NODE_NAME
  beaut_state_init
  store_init
}

cli_api_fail() {
  local body="${1:-}" fallback="${2:-request failed}" message
  message="$(beaut_api_error_text "$body")"
  [[ -n "$message" ]] || message="$fallback"
  beaut_warn "$message"
  return 1
}

# Read JSON through the hub API, falling back to a local provider function.
# The fallback function is called only after cli_local_hub has prepared state.
cli_read_json() {
  local path="$1"; shift
  local body
  if beaut_api_online && body="$(beaut_api_get "$path" 2>/dev/null)"; then
    printf '%s\n' "$body"
    return 0
  fi
  cli_local_hub
  "$@"
}

cli_workers_json() {
  cli_read_json /workers workers_json
}

cli_api_json_or() {
  local path="$1" fallback="$2" body
  if body="$(beaut_api_get "$path" 2>/dev/null)"; then
    printf '%s\n' "$body"
  else
    printf '%s\n' "$fallback"
  fi
}

cmd_init() {
  local force=0
  [[ "${1:-}" == "--force" ]] && force=1
  local target="$BEAUT_CONFIG"
  if [[ -f "$target" && "$force" != "1" ]]; then
    beaut_log "config already exists: $target"
    return 0
  fi
  cp -- "${BEAUT_ROOT}/beaut.conf.example" "$target" || return 1
  chmod 600 "$target" 2>/dev/null || true
  beaut_log "wrote $target; edit worker addresses and routes, then install"
}

cmd_config() {
  case "${1:-show}" in
    path) printf '%s\n' "$BEAUT_CONFIG" ;;
    show) beaut_config_show ;;
    edit) "${EDITOR:-vi}" "$BEAUT_CONFIG" ;;
    *) usage; return 2 ;;
  esac
}

cmd_hub() {
  case "${1:-}" in
    serve) exec "$BEAUT_ROOT/server/hub_server.sh" ;;
    *) usage; return 2 ;;
  esac
}

cmd_worker() {
  case "${1:-}" in
    serve) exec "$BEAUT_ROOT/server/worker_server.sh" ;;
    resources) shift; cmd_worker_resources "$@" ;;
    *) usage; return 2 ;;
  esac
}

cmd_worker_resources() {
  beaut_parse_options 'cpus,memory,disk,tags,max-sessions,write!' -- "$@" || {
    usage
    return 2
  }
  local -a lines=()
  local key var value
  for key in cpus memory disk tags max-sessions; do
    [[ -n "${BEAUT_OPT[$key]+set}" ]] || continue
    value="${BEAUT_OPT[$key]}"
    case "$key" in
      cpus) var=BEAUT_WORKER_CPUS ;;
      memory) var=BEAUT_WORKER_MEMORY_MB ;;
      disk) var=BEAUT_WORKER_DISK_MB ;;
      tags) var=BEAUT_WORKER_TAGS ;;
      max-sessions) var=BEAUT_WORKER_MAX_SESSIONS ;;
    esac
    lines+=("$(printf '%s=%q' "$var" "$value")")
  done
  if (( ${#lines[@]} == 0 )); then
    beaut_worker_resources_show
    return 0
  fi
  if [[ -n "${BEAUT_OPT[write]:-}" ]]; then
    local tmp
    [[ -f "$BEAUT_CONFIG" ]] || {
      beaut_warn "config not found: $BEAUT_CONFIG"
      return 1
    }
    tmp="$(mktemp "${BEAUT_CONFIG}.XXXXXX")" || return 1
    if ! beaut_worker_resources_write "$tmp" "${lines[@]}"; then
      rm -f -- "$tmp"
      return 1
    fi
    mv -f -- "$tmp" "$BEAUT_CONFIG"
    chmod 600 "$BEAUT_CONFIG" 2>/dev/null || true
    beaut_log "updated $BEAUT_CONFIG"
  else
    printf '%s\n' "${lines[@]}"
    beaut_log "append these lines to $BEAUT_CONFIG, or add --write"
  fi
}

cmd_router() {
  case "${1:-}" in
    run) router_run ;;
    sync) beaut_state_init; routes_seed; router_sync; beaut_log "router sync complete" ;;
    stop) router_stop_all; beaut_log "router listeners stopped" ;;
    *) usage; return 2 ;;
  esac
}

# ---- packages ---------------------------------------------------------------

cmd_package() {
  local action="${1:-}"; shift || true
  case "$action" in
    add|put) cmd_package_add "$@" ;;
    ls|list) cmd_package_ls "$@" ;;
    show) cmd_package_show "$@" ;;
    get) cmd_package_get "$@" ;;
    replicate) cmd_package_replicate "$@" ;;
    verify) cmd_package_verify "$@" ;;
    scrub) cmd_package_scrub "$@" ;;
    stats) cmd_package_stats "$@" ;;
    *) usage; return 2 ;;
  esac
}

cmd_package_add() {
  beaut_parse_options 'name,kind,copies,allow-degraded!' -- "$@" || {
    usage
    return 2
  }
  local file="${BEAUT_ARGS[0]:-}" tmp="" name kind copies response rc
  [[ -n "$file" ]] || { usage; return 2; }
  if [[ "$file" != "-" && ! -f "$file" ]]; then
    beaut_warn "not a regular file: $file"
    return 1
  fi
  name="${BEAUT_OPT[name]:-$(basename -- "$file")}"
  kind="${BEAUT_OPT[kind]:-$BEAUT_PACKAGE_KIND_DEFAULT}"
  copies="${BEAUT_OPT[copies]:-$BEAUT_MIN_COPIES}"
  if ! store_package_kind_valid "$kind"; then
    beaut_warn "unsupported package kind: $kind"
    return 2
  fi
  if [[ ! "$copies" =~ ^[0-9]+$ ]]; then
    beaut_warn "copies must be a number: $copies"
    return 2
  fi
  if [[ "$file" == "-" ]]; then
    tmp="$(mktemp "${TMPDIR:-/tmp}/beaut-stdin.XXXXXX")" || return 1
    if ! cat > "$tmp"; then
      rm -f -- "$tmp"
      return 1
    fi
    file="$tmp"
    [[ -n "${BEAUT_OPT[name]:-}" ]] || name="stdin-$(beaut_now)"
  fi
  if beaut_api_online; then
    local query
    query="name=$(beaut_url_encode "$name")&kind=$(beaut_url_encode "$kind")&copies=$(beaut_url_encode "$copies")"
    [[ -n "${BEAUT_OPT[allow-degraded]:-}" ]] && query+="&allow_degraded=1"
    response="$(beaut_api_request PUT "/packages?$query" "$file")"
    rc=$?
    [[ -n "$tmp" ]] && rm -f -- "$tmp"
    [[ -n "$response" ]] && beaut_api_payload "$response"
    if (( rc != 0 )) || ! beaut_api_ok "$response"; then
      if jq -e '.manifest.degraded == true' >/dev/null 2>&1 <<<"$response"; then
        beaut_warn "package has fewer copies than required"
        return 3
      fi
      beaut_warn "package upload failed"
      return 1
    fi
    return 0
  fi
  cli_local_hub
  local id manifest copyn degraded
  id="$(store_add_file "$file" "$name" "$kind" "$copies")" || {
    [[ -n "$tmp" ]] && rm -f -- "$tmp"
    return 1
  }
  store_replicate "$id" >/dev/null 2>&1 || true
  [[ -n "$tmp" ]] && rm -f -- "$tmp"
  manifest="$(store_manifest "$id")"
  copyn="$(jq -r '.copies | length' <<<"$manifest")"
  degraded="$(jq -r '.degraded' <<<"$manifest")"
  printf '%s\n' "$manifest"
  if [[ "$degraded" == "true" && "${BEAUT_STRICT_COPIES:-1}" == "1" \
        && -z "${BEAUT_OPT[allow-degraded]:-}" ]]; then
    beaut_warn "package has $copyn/$copies copies; add workers or retry package replicate"
    return 3
  fi
}

cmd_package_ls() {
  beaut_parse_options 'json!' -- "$@" || { usage; return 2; }
  local json
  json="$(cli_read_json /packages store_list)"
  if [[ -n "${BEAUT_OPT[json]:-}" ]]; then
    printf '%s\n' "$json"
  else
    report_packages "$json"
  fi
}

cmd_package_show() {
  local id="${1:-}"
  [[ -n "$id" ]] || { usage; return 2; }
  local json
  if beaut_api_online; then
    json="$(beaut_api_get "/packages/$(beaut_url_encode "$id")")" || {
      cli_api_fail "$json" "package not found: $id"
      return 1
    }
    printf '%s\n' "$json"
    return 0
  fi
  cli_local_hub
  store_manifest_exists "$id" || store_fetch "$id" || true
  store_manifest "$id"
}

cmd_package_get() {
  local id="${1:-}" output="${2:-}"
  [[ -n "$id" && -n "$output" ]] || { usage; return 2; }
  if beaut_api_online; then
    if ! beaut_api_download "/packages/$(beaut_url_encode "$id")/download" "$output"; then
      beaut_warn "package download failed: $id"
      return 1
    fi
    beaut_log "wrote $output"
    return 0
  fi
  cli_local_hub
  store_fetch "$id" || {
    beaut_warn "package not found or incomplete: $id"
    return 1
  }
  store_get_file "$id" "$output" || {
    beaut_warn "could not reconstruct package: $id"
    return 1
  }
  beaut_log "wrote $output"
}

cmd_package_replicate() {
  local id="${1:-}"
  [[ -n "$id" ]] || { usage; return 2; }
  local response rc
  if beaut_api_online; then
    response="$(beaut_api_post "/packages/$(beaut_url_encode "$id")/replicate")"
    rc=$?
    [[ -n "$response" ]] && beaut_api_payload "$response"
    (( rc == 0 )) || {
      beaut_warn "replication incomplete: $id"
      return 1
    }
    return 0
  fi
  cli_local_hub
  store_replicate "$id"
}

cmd_package_verify() {
  beaut_parse_options 'full!' -- "$@" || { usage; return 2; }
  local id="${BEAUT_ARGS[0]:-}"
  [[ -n "$id" ]] || { usage; return 2; }
  local full=0 response
  [[ -n "${BEAUT_OPT[full]:-}" ]] && full=1
  if beaut_api_online; then
    response="$(beaut_api_post "/packages/$(beaut_url_encode "$id")/verify?full=$full")" || {
      cli_api_fail "$response" "package verification failed: $id"
      return 1
    }
    beaut_log "package verified: $id"
    return 0
  fi
  cli_local_hub
  store_verify "$id" "$full" || return 1
  beaut_log "package verified: $id"
}

cmd_package_scrub() {
  beaut_parse_options 'json!' -- "$@" || { usage; return 2; }
  local response rc=0
  if beaut_api_online; then
    response="$(beaut_api_post /store/scrub)" || rc=$?
  else
    cli_local_hub
    response="$(store_scrub_json)" || rc=$?
  fi
  if [[ -n "${BEAUT_OPT[json]:-}" ]]; then
    printf '%s\n' "$response"
  else
    report_scrub "$response"
  fi
  (( rc == 0 )) || beaut_warn "scrub found damaged packages"
  return "$rc"
}

cmd_package_stats() {
  beaut_parse_options 'json!' -- "$@" || { usage; return 2; }
  local json
  json="$(cli_read_json /store/stats store_stats)"
  if [[ -n "${BEAUT_OPT[json]:-}" ]]; then
    printf '%s\n' "$json"
  else
    report_store_stats "$json"
  fi
}

# ---- routes -----------------------------------------------------------------

cmd_route() {
  local action="${1:-}"; shift || true
  case "$action" in
    add) cmd_route_add "$@" ;;
    ls|list) cmd_route_ls "$@" ;;
    rm|remove) cmd_route_rm "$@" ;;
    find) cmd_route_find "$@" ;;
    sync) cmd_route_sync "$@" ;;
    *) usage; return 2 ;;
  esac
}

cmd_route_add() {
  (( $# >= 5 )) || { usage; return 2; }
  local name="$1" host="$2" path="$3" worker="$4" port="$5"
  local mode="${6:-http}" hub="${7:-$BEAUT_HUB_NAME}" listen="${8:-}"
  local body response
  if [[ ! "$port" =~ ^[0-9]+$ || ( "$mode" != "http" && "$mode" != "tcp" ) \
        || ( -n "$listen" && ! "$listen" =~ ^[0-9]+$ ) ]]; then
    beaut_warn "invalid route port or mode"
    return 2
  fi
  if beaut_api_online; then
    body="$(jq -cn --arg name "$name" --arg host "$host" --arg path "$path" \
      --arg worker "$worker" --argjson port "$port" --arg mode "$mode" \
      --arg hub "$hub" --arg listen "$listen" \
      '{name:$name,host:$host,path:$path,worker:$worker,port:$port,
        mode:$mode,hub:$hub,listen_port:($listen|tonumber? // null)}')" || return 1
    response="$(beaut_api_post /routes "$body")" || {
      cli_api_fail "$response" "could not add route: $name"
      return 1
    }
    report_routes "$response"
    return 0
  fi
  cli_local_hub
  route_add "$name" "$host" "$path" "$worker" "$port" "$mode" "$hub" "$listen" || {
    beaut_warn "invalid route"
    return 1
  }
  report_routes "$(routes_json)"
}

cmd_route_ls() {
  beaut_parse_options 'json!' -- "$@" || { usage; return 2; }
  local json
  json="$(cli_read_json /routes routes_json)"
  if [[ -n "${BEAUT_OPT[json]:-}" ]]; then
    printf '%s\n' "$json"
  else
    report_routes "$json"
  fi
}

cmd_route_rm() {
  local name="${1:-}"
  [[ -n "$name" ]] || { usage; return 2; }
  if beaut_api_online; then
    local response
    response="$(beaut_api_delete "/routes/$(beaut_url_encode "$name")")" || {
      cli_api_fail "$response" "could not remove route: $name"
      return 1
    }
  else
    cli_local_hub
    route_remove "$name" || {
      beaut_warn "could not remove route: $name"
      return 1
    }
  fi
  beaut_log "route removed: $name"
}

cmd_route_find() {
  local host="${1:-}" path="${2:-}"
  [[ -n "$host" && -n "$path" ]] || { usage; return 2; }
  local json
  if beaut_api_online; then
    json="$(beaut_api_get "/routes/find?host=$(beaut_url_encode "$host")&path=$(beaut_url_encode "$path")")" || {
      cli_api_fail "$json" "no route"
      return 1
    }
    printf '%s\n' "$json"
    return 0
  fi
  cli_local_hub
  local row
  row="$(route_find "$host" "$path")" || {
    beaut_warn "no route"
    return 1
  }
  route_row_json "$row"
}

cmd_route_sync() {
  cli_local_hub
  routes_seed
  report_routes "$(routes_json)"
}

# ---- sessions ---------------------------------------------------------------

cmd_session() {
  local action="${1:-}"; shift || true
  case "$action" in
    create) cmd_session_create "$@" ;;
    ls|list) cmd_session_ls "$@" ;;
    show) cmd_session_show "$@" ;;
    stop|start|snapshot) cmd_session_action "$action" "$@" ;;
    restore) cmd_session_restore "$@" ;;
    move) cmd_session_move "$@" ;;
    exec) cmd_session_exec "$@" ;;
    rm|remove) cmd_session_rm "$@" ;;
    *) usage; return 2 ;;
  esac
}

cmd_session_create() {
  beaut_parse_options 'worker,port,protocol,command+' -- "$@" || {
    usage
    return 2
  }
  local name="${BEAUT_ARGS[0]:-}" image="${BEAUT_ARGS[1]:-}"
  [[ -n "$name" && -n "$image" ]] || { usage; return 2; }
  local worker="${BEAUT_OPT[worker]:-}" port="${BEAUT_OPT[port]:-$BEAUT_SESSION_PORT}"
  local protocol="${BEAUT_OPT[protocol]:-$BEAUT_SESSION_PROTOCOL}" command_json='[]'
  local -a commands=()
  if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    beaut_warn "port must be a number: $port"
    return 2
  fi
  if [[ -n "${BEAUT_OPT_MULTI[command]:-}" ]]; then
    mapfile -t commands < <(printf '%s' "${BEAUT_OPT_MULTI[command]}")
  fi
  if (( ${#commands[@]} > 0 )); then
    command_json="$(jq -cn --args '$ARGS.positional' -- "${commands[@]}")" || return 1
  fi
  local body response
  if beaut_api_online; then
    body="$(jq -cn --arg name "$name" --arg image "$image" --arg worker "$worker" \
      --argjson port "$port" --arg protocol "$protocol" \
      --argjson command "$command_json" \
      '{name:$name,image:$image,worker:$worker,container_port:$port,
        protocol:$protocol,command:$command}')" || return 1
    response="$(beaut_api_post /sessions "$body")" || {
      cli_api_fail "$response" "session create failed"
      return 1
    }
    beaut_api_payload "$response"
    return 0
  fi
  cli_local_hub
  session_create "$name" "$image" "$worker" "$port" "$protocol" "$command_json"
}

cmd_session_ls() {
  beaut_parse_options 'json!' -- "$@" || { usage; return 2; }
  local json
  json="$(cli_read_json /sessions session_list)"
  if [[ -n "${BEAUT_OPT[json]:-}" ]]; then
    printf '%s\n' "$json"
  else
    report_sessions "$json"
  fi
}

cmd_session_show() {
  local id="${1:-}"
  [[ -n "$id" ]] || { usage; return 2; }
  local json
  if beaut_api_online; then
    json="$(beaut_api_get "/sessions/$(beaut_url_encode "$id")")" || {
      cli_api_fail "$json" "session not found"
      return 1
    }
    printf '%s\n' "$json"
    return 0
  fi
  cli_local_hub
  session_get "$id" || {
    beaut_warn "session not found"
    return 1
  }
}

cmd_session_action() {
  local action="$1" id="${2:-}"
  [[ -n "$id" ]] || { usage; return 2; }
  local response
  if beaut_api_online; then
    response="$(beaut_api_post "/sessions/$(beaut_url_encode "$id")/$action")" || {
      cli_api_fail "$response" "session $action failed"
      return 1
    }
    beaut_api_payload "$response"
    return 0
  fi
  cli_local_hub
  "session_${action}" "$id"
}

cmd_session_restore() {
  beaut_parse_options 'worker' -- "$@" || { usage; return 2; }
  local id="${BEAUT_ARGS[0]:-}"
  [[ -n "$id" ]] || { usage; return 2; }
  local worker="${BEAUT_OPT[worker]:-}" body response
  if beaut_api_online; then
    if [[ -n "$worker" ]]; then
      body="$(jq -cn --arg worker "$worker" '{worker:$worker}')" || return 1
    else
      body='{}'
    fi
    response="$(beaut_api_post "/sessions/$(beaut_url_encode "$id")/restore" "$body")" || {
      cli_api_fail "$response" "session restore failed"
      return 1
    }
    beaut_api_payload "$response"
    return 0
  fi
  cli_local_hub
  session_restore "$id" "$worker"
}

cmd_session_move() {
  local id="${1:-}" worker="${2:-}"
  [[ -n "$id" && -n "$worker" ]] || { usage; return 2; }
  local body response
  if beaut_api_online; then
    body="$(jq -cn --arg worker "$worker" '{worker:$worker}')" || return 1
    response="$(beaut_api_post "/sessions/$(beaut_url_encode "$id")/move" "$body")" || {
      cli_api_fail "$response" "session move failed"
      return 1
    }
    beaut_api_payload "$response"
    return 0
  fi
  cli_local_hub
  session_move "$id" "$worker"
}

cmd_session_exec() {
  local id="${1:-}"; shift || true
  [[ "${1:-}" == "--" ]] && shift
  [[ -n "$id" ]] || { usage; return 2; }
  (( $# > 0 )) || { usage; return 2; }
  local command_json body response rc
  command_json="$(jq -cn --args '$ARGS.positional' -- "$@")" || return 1
  if beaut_api_online; then
    body="$(jq -cn --argjson command "$command_json" '{command:$command}')" || return 1
    response="$(beaut_api_post "/sessions/$(beaut_url_encode "$id")/exec" "$body")" || {
      cli_api_fail "$response" "session exec failed"
      return 1
    }
  else
    cli_local_hub
    response="$(session_exec "$id" "$command_json")" || {
      cli_api_fail "$response" "session exec failed"
      return 1
    }
  fi
  jq -r '.output // empty' <<<"$response"
  rc="$(jq -r '.exit_code // 0' <<<"$response" 2>/dev/null || printf '0')"
  [[ "$rc" =~ ^[0-9]+$ ]] || rc=0
  return "$rc"
}

cmd_session_rm() {
  local id="${1:-}"
  [[ -n "$id" ]] || { usage; return 2; }
  if beaut_api_online; then
    local response
    response="$(beaut_api_delete "/sessions/$(beaut_url_encode "$id")")" || {
      cli_api_fail "$response" "could not remove session: $id"
      return 1
    }
  else
    cli_local_hub
    session_remove "$id" || {
      beaut_warn "could not remove session: $id"
      return 1
    }
  fi
  beaut_log "session removed: $id"
}

# ---- status and diagnostics -------------------------------------------------

cmd_workers() {
  beaut_parse_options 'json!' -- "$@" || { usage; return 2; }
  local json
  json="$(cli_workers_json)"
  if [[ -n "${BEAUT_OPT[json]:-}" ]]; then
    printf '%s\n' "$json"
  else
    report_workers "$json"
  fi
}

cmd_status() {
  local source health workers sessions stats routes
  if beaut_api_online; then
    source=api
    health=ok
    workers="$(cli_api_json_or /workers '[]')"
    sessions="$(cli_api_json_or /sessions '[]')"
    stats="$(cli_api_json_or /store/stats '{"objects":0,"packages":0,"bytes":0}')"
    routes="$(cli_api_json_or /routes '[]')"
  else
    source=local
    health=unreachable
    cli_local_hub
    workers="$(workers_json)"
    sessions="$(session_list)"
    stats="$(store_stats)"
    routes="$(routes_json)"
  fi
  report_status "$source" "$health" "$workers" "$sessions" "$stats" "$routes"
}

cmd_doctor() {
  local failed=0 command_name workers
  printf 'beaut %s\n' "$BEAUT_VERSION"
  printf 'config: %s\n' "$BEAUT_CONFIG"
  for command_name in jq curl tar gzip socat; do
    if beaut_has "$command_name"; then
      report_doctor_line ok "$command_name"
    else
      report_doctor_line MISSING "$command_name"
      failed=1
    fi
  done
  if beaut_has "${BEAUT_DOCKER:-docker}"; then
    report_doctor_line ok "${BEAUT_DOCKER:-docker} ($("${BEAUT_DOCKER:-docker}" --version 2>/dev/null | head -1))"
  else
    report_doctor_line warn "docker not found (workers cannot run sessions)"
  fi
  if [[ -w "$BEAUT_STATE_DIR" || ! -e "$BEAUT_STATE_DIR" ]]; then
    report_doctor_line ok "state dir writable: $BEAUT_STATE_DIR"
  else
    report_doctor_line warn "state dir not writable: $BEAUT_STATE_DIR"
    failed=1
  fi
  if beaut_has jq && beaut_has curl; then
    if beaut_api_online; then
      report_doctor_line ok "hub reachable: $BEAUT_HUB_URL"
    else
      report_doctor_line warn "hub unreachable: $BEAUT_HUB_URL"
    fi
    workers="$(cli_workers_json)"
    printf 'workers:\n'
    report_workers "$workers"
  else
    report_doctor_line warn "jq/curl missing; cannot query hub or workers"
  fi
  return "$failed"
}

cmd_deploy() {
  require_common
  beaut_require ssh sftp
  deploy_command "$@"
}

# ---- entry point ------------------------------------------------------------

beaut_cli_main() {
  local -a args=()
  local requested=""
  while (( $# )); do
    case "$1" in
      --config|-c)
        if [[ -z "${2:-}" ]]; then
          printf 'missing value for %s\n' "$1" >&2
          return 2
        fi
        BEAUT_CONFIG="$2"
        shift 2
        ;;
      --help|-h)
        requested=help
        break
        ;;
      --version|-V)
        requested=version
        break
        ;;
      --)
        shift
        args+=("$@")
        break
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done
  if [[ -n "$requested" ]]; then
    set -- "$requested"
  elif (( ${#args[@]} > 0 )); then
    set -- "${args[@]}"
  fi
  if [[ -z "${BEAUT_CONFIG:-}" ]]; then
    BEAUT_CONFIG="${BEAUT_ROOT}/beaut.conf"
    # An installed tree keeps its operator config in BEAUT_CONFIG_DIR.
    if [[ ! -f "$BEAUT_CONFIG" && -f "${BEAUT_CONFIG_DIR}/beaut.conf" ]]; then
      BEAUT_CONFIG="${BEAUT_CONFIG_DIR}/beaut.conf"
    fi
  fi
  export BEAUT_CONFIG
  beaut_load_config

  local command="${1:-help}"
  shift || true
  case "$command" in
    help|usage)
      case "${1:-}" in
        api) usage_api ;;
        *) usage ;;
      esac
      ;;
    version) printf 'beaut %s\n' "$BEAUT_VERSION" ;;
    init) cmd_init "$@" ;;
    config) cmd_config "$@" ;;
    #hub) require_common; cmd_hub "$@" ;;
    hub) exec "$BEAUT_ROOT/server/hub_server.sh" ;;
    worker) require_common; cmd_worker "$@" ;;
    router) require_common; cmd_router "$@" ;;
    install|deploy) cmd_deploy "$@" ;;
    package|pkg) require_common; cmd_package "$@" ;;
    route|routes) require_common; cmd_route "$@" ;;
    session|sessions) require_common; cmd_session "$@" ;;
    workers) require_common; cmd_workers "$@" ;;
    status) require_common; cmd_status "$@" ;;
    doctor) cmd_doctor "$@" ;;
    *) usage >&2; return 2 ;;
  esac
}
