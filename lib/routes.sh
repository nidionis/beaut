#!/usr/bin/env bash
# routes.sh - domain/path to worker:port map, HTTP proxy resolution and the
# optional raw-TCP router.

ROUTES_FILE() {
  printf '%s' "${BEAUT_STATE_DIR}/routes.tsv"
}

routes_seed() {
  local entry name host path worker port mode hub listen enabled row
  local existing
  beaut_state_lock 5 || return 1
  die() { beaut_state_unlock; beaut_warn "$*"; return 1; }
  for entry in "${BEAUT_ROUTES[@]:-}"; do
    [[ -n "$entry" ]] || continue
    IFS='|' read -r name host path worker port mode hub listen <<<"$entry"
    [[ -n "$name" ]] || continue
    if [[ -z "$path" ]]; then path="/"; fi
    [[ -n "$mode" ]] || mode="$BEAUT_ROUTE_MODE_DEFAULT"
    [[ -n "$listen" ]] || listen=""
    existing="$(awk -F'\t' -v n="$name" '$1==n {print $1}' "$(ROUTES_FILE)" | head -1)"
    [[ -n "$existing" ]] && continue
    printf '%s|%s|%s|%s|%s|%s|%s|%s|1\n' \
      "$name" "$host" "$path" "$worker" "$port" "$mode" "$hub" "$listen" >> "$(ROUTES_FILE)"
  done
  beaut_state_unlock
  return 0
}

routes_list() {
  [[ -f "$(ROUTES_FILE)" ]] && cat -- "$(ROUTES_FILE)" || true
}

routes_json() {
  local line name host path worker port mode hub listen enabled
  local -a rows=()
  while IFS='|' read -r name host path worker port mode hub listen enabled; do
    [[ -n "$name" ]] || continue
    rows+=("$(jq -cn --arg name "$name" --arg host "$host" --arg path "$path" \
      --arg worker "$worker" --arg port "$port" --arg mode "$mode" \
      --arg hub "$hub" --arg listen "$listen" --arg enabled "$enabled" \
      '{name:$name,host:$host,path:$path,worker:$worker,
        port:($port|tonumber? // null),mode:$mode,preferred_hub:$hub,
        listen_port:($listen|tonumber? // null),enabled:($enabled != "0")}')")
  done < <(routes_list)
  if (( ${#rows[@]} == 0 )); then
    printf '[]\n'
  else
    printf '%s\n' "${rows[@]}" | jq -s '.'
  fi
}

route_add() {
  local name host path worker port mode hub listen enabled row
  name="$(beaut_sanitize_name "${1:-}")"
  host="${2:-*}"
  path="${3:-/}"
  worker="${4:-}"
  port="${5:-}"
  mode="${6:-$BEAUT_ROUTE_MODE_DEFAULT}"
  hub="${7:-}"
  listen="${8:-}"
  enabled="${9:-1}"
  [[ -n "$name" && -n "$worker" && "$port" =~ ^[0-9]+$ ]] || return 1
  [[ "$path" == /* ]] || path="/$path"
  local allowed found=0
  for allowed in "${BEAUT_ROUTE_MODES[@]}"; do
    [[ "$allowed" == "$mode" ]] && { found=1; break; }
  done
  (( found == 1 )) || return 1
  [[ -z "$listen" || "$listen" =~ ^[0-9]+$ ]] || return 1
  beaut_state_lock 5 || return 1
  local tmp
  tmp="$(mktemp "${BEAUT_STATE_DIR}/routes.XXXXXX")" || {
    beaut_state_unlock
    return 1
  }
  awk -F'|' -v n="$name" '$1 != n' "$(ROUTES_FILE)" > "$tmp" 2>/dev/null || true
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$name" "$host" "$path" "$worker" "$port" "$mode" "$hub" "$listen" "$enabled" >> "$tmp"
  mv -f -- "$tmp" "$(ROUTES_FILE)"
  beaut_state_unlock
}

route_remove() {
  local name="$1" tmp
  beaut_state_lock 5 || return 1
  tmp="$(mktemp "${BEAUT_STATE_DIR}/routes.XXXXXX")" || {
    beaut_state_unlock
    return 1
  }
  awk -F'|' -v n="$name" '$1 != n' "$(ROUTES_FILE)" > "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$(ROUTES_FILE)"
  beaut_state_unlock
}

# Prints the best matching state row.  Exact host beats wildcard, longer path
# beats shorter path, and a route preferring the local hub wins a tie.
route_find() {
  local wanted_host="${1:-}" wanted_path="${2:-/}" local_hub="${BEAUT_HUB_NAME:-}"
  local best="" best_score=-1 name host path worker port mode hub listen enabled
  # HTTP Host headers include the port unless it is the scheme default.
  if [[ "$wanted_host" == \[*\]* ]]; then
    wanted_host="${wanted_host#\[}"
    wanted_host="${wanted_host%%\]*}"
  else
    wanted_host="${wanted_host%%:*}"
  fi
  local score host_score path_len path_score
  while IFS='|' read -r name host path worker port mode hub listen enabled; do
    [[ -n "$name" ]] || continue
    [[ "${enabled:-1}" == "0" ]] && continue
    [[ -n "$path" ]] || path="/"
    if [[ "$path" == "/" ]]; then
      :
    else
      case "$wanted_path" in
        "$path"|"$path"/*) ;;
        *) continue ;;
      esac
    fi
    host_score=1
    if [[ "$host" == "$wanted_host" ]]; then
      host_score=2
    elif [[ -z "$host" || "$host" == "*" ]]; then
      host_score=1
    else
      continue
    fi
    path_len="${#path}"
    path_score="$path_len"
    score=$((host_score * 100000 + path_score))
    if [[ -n "$local_hub" && "$hub" == "$local_hub" ]]; then
      score=$((score + 1000))
    fi
    if (( score > best_score )); then
      best_score="$score"
      best="$name|$host|$path|$worker|$port|$mode|$hub|$listen|$enabled"
    fi
  done < <(routes_list)
  [[ -n "$best" ]] || return 1
  printf '%s\n' "$best"
}

route_parts() {
  local row="$1"
  ROUTE_NAME="" ROUTE_HOST="" ROUTE_PATH="" ROUTE_WORKER=""
  ROUTE_PORT="" ROUTE_MODE="" ROUTE_HUB="" ROUTE_LISTEN="" ROUTE_ENABLED=""
  IFS='|' read -r ROUTE_NAME ROUTE_HOST ROUTE_PATH ROUTE_WORKER \
    ROUTE_PORT ROUTE_MODE ROUTE_HUB ROUTE_LISTEN ROUTE_ENABLED <<<"$row"
}

route_row_json() {
  local row="$1"
  route_parts "$row"
  jq -cn \
    --arg name "$ROUTE_NAME" --arg host "$ROUTE_HOST" --arg path "$ROUTE_PATH" \
    --arg worker "$ROUTE_WORKER" --arg port "$ROUTE_PORT" --arg mode "$ROUTE_MODE" \
    --arg hub "$ROUTE_HUB" --arg listen "$ROUTE_LISTEN" \
    --argjson enabled "$([[ "${ROUTE_ENABLED:-1}" == "0" ]] && echo false || echo true)" \
    '{name:$name,host:$host,path:$path,worker:$worker,
      port:($port|tonumber? // null),mode:$mode,preferred_hub:$hub,
      listen_port:($listen|tonumber? // null),enabled:$enabled}'
}

route_target() {
  local row="$1" host port
  route_parts "$row"
  if worker_row="$(worker_find "$ROUTE_WORKER" 2>/dev/null)"; then
    # The worker record supplies the reachable host; the route supplies the
    # service port inside that worker (falling back to the worker API port).
    IFS='|' read -r _ host port _ _ <<<"$worker_row"
    port="${ROUTE_PORT:-$port}"
  else
    host="$ROUTE_WORKER"
    port="$ROUTE_PORT"
  fi
  [[ -n "$host" && -n "$port" ]] || return 1
  printf '%s|%s\n' "$host" "$port"
}

route_proxy_url() {
  local row="$1" requested_path="${2:-/}" target host port prefix remainder
  target="$(route_target "$row")" || return 1
  IFS='|' read -r host port <<<"$target"
  route_parts "$row"
  prefix="$ROUTE_PATH"
  [[ "$prefix" == "/" ]] && prefix=""
  if [[ -n "$prefix" && "$requested_path" == "$prefix"* ]]; then
    remainder="${requested_path#"$prefix"}"
  else
    remainder="$requested_path"
  fi
  [[ "$remainder" == /* ]] || remainder="/$remainder"
  [[ -n "${HTTP_QUERY:-}" ]] && remainder="${remainder}?${HTTP_QUERY}"
  printf 'http://%s:%s%s' "$host" "$port" "$remainder"
}

# ---- raw TCP router --------------------------------------------------------
router_sync() {
  local dir="${BEAUT_ROUTER_DIR:-$BEAUT_STATE_DIR/run/router}"
  local line name host path worker port mode hub listen enabled target pidfile pid wanted
  local -A wanted_ports=()
  mkdir -p -- "$dir"
  while IFS='|' read -r name host path worker port mode hub listen enabled; do
    [[ -n "$name" && "$mode" == "tcp" && "$listen" =~ ^[0-9]+$ ]] || continue
    [[ "${enabled:-1}" == "0" ]] && continue
    target="$(route_target "$name|$host|$path|$worker|$port|$mode|$hub|$listen|$enabled")" || continue
    wanted_ports["$listen"]="$target"
  done < <(routes_list)

  local public
  for public in "${!wanted_ports[@]}"; do
    target="${wanted_ports[$public]}"
    pidfile="$dir/$public.pid"
    pid="$(beaut_read_pid "$pidfile")"
    if beaut_pid_alive "$pid" && [[ "$(cat "$dir/$public.target" 2>/dev/null || true)" == "$target" ]]; then
      continue
    fi
    beaut_stop_pidfile "$pidfile"
    printf '%s\n' "$target" > "$dir/$public.target"
    socat "TCP-LISTEN:${public},fork,reuseaddr" "TCP:${target/|/:}" >> "$dir/router.log" 2>&1 &
    beaut_write_pid "$pidfile" "$!"
    beaut_log "tcp route :$public -> $target"
  done

  local pidfile_file
  for pidfile_file in "$dir"/*.pid; do
    [[ -f "$pidfile_file" ]] || continue
    public="${pidfile_file##*/}"; public="${public%.pid}"
    [[ -n "${wanted_ports[$public]:-}" ]] || beaut_stop_pidfile "$pidfile_file"
  done
}

router_run() {
  local interval="${BEAUT_ROUTER_INTERVAL:-1}"
  mkdir -p -- "${BEAUT_ROUTER_DIR:-$BEAUT_STATE_DIR/run/router}"
  trap 'router_stop_all; exit 0' INT TERM
  while :; do
    routes_seed >/dev/null 2>&1 || true
    router_sync
    sleep "$interval"
  done
}

router_stop_all() {
  local pidfile
  for pidfile in "${BEAUT_ROUTER_DIR:-$BEAUT_STATE_DIR/run/router}"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    beaut_stop_pidfile "$pidfile"
  done
}
