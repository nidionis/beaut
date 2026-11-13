#!/usr/bin/env bash
# sessions.sh - hub-side persistent Docker session records and routing.

session_dir() {
  printf '%s/sessions' "$BEAUT_STATE_DIR"
}

session_path() {
  local id
  id="$(beaut_sanitize_name "$1")"
  printf '%s/%s.json' "$(session_dir)" "$id"
}

session_id() {
  printf '%s%s' "$BEAUT_SESSION_ID_PREFIX" "$(beaut_rand_hex 8)"
}

session_write() {
  local id="$1" json="$2"
  beaut_atomic_write "$(session_path "$id")" "$json"
}

session_get() {
  local path
  path="$(session_path "$1")"
  [[ -f "$path" ]] && cat -- "$path"
}

session_list() {
  local file
  local -a files=()
  shopt -s nullglob
  files=("$(session_dir)"/*.json)
  shopt -u nullglob
  if (( ${#files[@]} == 0 )); then
    printf '[]\n'
    return 0
  fi
  jq -s 'sort_by(.created_at) | reverse' "${files[@]}"
}

session_worker_target() {
  local session="$1" worker host port
  worker="$(jq -r '.worker // ""' <<<"$session")"
  [[ -n "$worker" ]] || return 1
  host="$(worker_host "$worker")" || return 1
  port="$(worker_port "$worker")" || return 1
  printf '%s|%s' "$host" "$port"
}

session_call() {
  local worker="$1" path="$2" body_file="${3:-}" response
  local base
  base="$(worker_url "$worker")" || return 1
  local -a args=(-sS --connect-timeout 3 --max-time "${BEAUT_REPLICA_TIMEOUT:-30}" -X POST)
  if [[ -n "$body_file" && -f "$body_file" ]]; then
    args+=(-H 'Content-Type: application/json' --data-binary "@$body_file")
  fi
  if ! response="$(curl "${args[@]}" "${base}${path}" 2>/dev/null)"; then
    printf 'worker %s is unreachable\n' "$worker" >&2
    return 1
  fi
  jq -e '.ok == true' >/dev/null 2>&1 <<<"$response" || {
    printf '%s\n' "$response" >&2
    return 1
  }
  printf '%s\n' "$response"
}

session_route_add() {
  local id="$1" host_port="$2" worker="$3"
  route_add "${BEAUT_SESSION_ROUTE_PREFIX}${id}" '*' "/s/${id}/" "$worker" \
    "$host_port" "$BEAUT_ROUTE_MODE_DEFAULT" "$BEAUT_HUB_NAME" "" 1 >/dev/null
}

session_route_remove() {
  route_remove "${BEAUT_SESSION_ROUTE_PREFIX}${1}" >/dev/null 2>&1 || true
}

session_create() {
  local name="$1" image="$2" worker="${3:-}" container_port="${4:-$BEAUT_SESSION_PORT}"
  local protocol="${5:-$BEAUT_SESSION_PROTOCOL}" command_json="${6:-[]}"
  local id spec spec_file response host_port snapshot created json
  [[ -n "$name" && -n "$image" ]] || return 1
  [[ "$container_port" =~ ^[0-9]+$ ]] || container_port="$BEAUT_SESSION_PORT"
  if [[ -z "$worker" ]]; then
    worker="$(worker_choose "$BEAUT_HUB_NAME")" || {
      beaut_warn "no online worker with free session slots"
      return 1
    }
  fi
  worker_find "$worker" >/dev/null || {
    beaut_warn "unknown worker: $worker"
    return 1
  }
  id="$(session_id)"
  spec="$(jq -cn --arg id "$id" --arg name "$name" --arg image "$image" \
    --argjson port "$container_port" --arg protocol "$protocol" \
    --argjson command "$command_json" \
    '{id:$id,name:$name,image:$image,container_port:$port,
      protocol:$protocol,command:$command}')" || return 1
  spec_file="$(mktemp "${TMPDIR:-/tmp}/beaut-session.XXXXXX")" || return 1
  printf '%s\n' "$spec" > "$spec_file"
  if ! response="$(session_call "$worker" "/sessions/run" "$spec_file")"; then
    rm -f -- "$spec_file"
    beaut_warn "worker $worker rejected the session"
    return 1
  fi
  rm -f -- "$spec_file"
  host_port="$(jq -r '.host_port // 0' <<<"$response")"
  created="$(beaut_iso)"
  json="$(jq -cn --arg id "$id" --arg name "$name" --arg worker "$worker" \
    --arg image "$image" --argjson container_port "$container_port" \
    --argjson host_port "$host_port" --arg protocol "$protocol" \
    --argjson command "$command_json" --arg created "$created" \
    --arg host "$(worker_host "$worker")" \
    '{id:$id,name:$name,worker:$worker,worker_host:$host,image:$image,
      container_port:$container_port,host_port:$host_port,protocol:$protocol,
      command:$command,status:"running",snapshot:"",snapshot_image:"",
      created_at:$created,updated_at:$created}')" || return 1
  session_write "$id" "$json"
  session_route_add "$id" "$host_port" "$worker"
  printf '%s\n' "$json"
}

session_refresh_route() {
  local id="$1" session host_port worker
  session="$(session_get "$id")" || return 1
  host_port="$(jq -r '.host_port // 0' <<<"$session")"
  worker="$(jq -r '.worker // ""' <<<"$session")"
  [[ "$host_port" =~ ^[0-9]+$ ]] && (( host_port > 0 )) || return 1
  session_route_add "$id" "$host_port" "$worker"
}

session_stop() {
  local id="$1" session worker response snapshot
  session="$(session_get "$id")" || return 1
  worker="$(jq -r '.worker' <<<"$session")"
  if [[ "${BEAUT_SESSION_SNAPSHOT_ON_STOP:-1}" == "1" ]]; then
    session_snapshot "$id" >/dev/null 2>&1 || beaut_warn "snapshot before stop failed for $id"
    session="$(session_get "$id")"
  fi
  response="$(session_call "$worker" "/sessions/${id}/stop")" || return 1
  snapshot="$(jq -r '.snapshot // ""' <<<"$session")"
  session="$(jq -c --arg ts "$(beaut_iso)" --arg snapshot "$snapshot" \
    '.status="stopped" | .updated_at=$ts | .snapshot=$snapshot' <<<"$session")"
  session_write "$id" "$session"
  session_route_remove "$id"
  printf '%s\n' "$session"
}

session_start() {
  local id="$1" session worker response host_port
  session="$(session_get "$id")" || return 1
  worker="$(jq -r '.worker' <<<"$session")"
  response="$(session_call "$worker" "/sessions/${id}/start")" || return 1
  host_port="$(jq -r '.host_port // 0' <<<"$response")"
  session="$(jq -c --arg ts "$(beaut_iso)" --argjson host_port "$host_port" \
    '.status="running" | .updated_at=$ts | .host_port=$host_port' <<<"$session")"
  session_write "$id" "$session"
  session_refresh_route "$id" || true
  printf '%s\n' "$session"
}

session_snapshot() {
  local id="$1" session worker response snapshot image
  session="$(session_get "$id")" || return 1
  worker="$(jq -r '.worker' <<<"$session")"
  response="$(session_call "$worker" "/sessions/${id}/snapshot")" || return 1
  snapshot="$(jq -r '.snapshot // ""' <<<"$response")"
  image="$(jq -r '.image // ""' <<<"$response")"
  session="$(jq -c --arg ts "$(beaut_iso)" --arg snapshot "$snapshot" --arg image "$image" \
    '.updated_at=$ts | .snapshot=$snapshot | .snapshot_image=$image' <<<"$session")"
  session_write "$id" "$session"
  printf '%s\n' "$response"
}

session_restore() {
  local id="$1" worker="${2:-}" session snapshot image response host_port body old_worker
  session="$(session_get "$id")" || return 1
  old_worker="$(jq -r '.worker // ""' <<<"$session")"
  snapshot="$(jq -r '.snapshot // ""' <<<"$session")"
  [[ -n "$snapshot" ]] || {
    beaut_warn "session $id has no snapshot"
    return 1
  }
  image="$(jq -r '.snapshot_image // ""' <<<"$session")"
  [[ -n "$worker" ]] || worker="$(jq -r '.worker' <<<"$session")"
  worker_find "$worker" >/dev/null || return 1
  body="$(mktemp "${TMPDIR:-/tmp}/beaut-restore.XXXXXX")" || return 1
  jq -cn --arg id "$id" --arg snapshot "$snapshot" --arg image "$image" \
    --arg name "$(jq -r '.name // .id' <<<"$session")" \
    --argjson container_port "$(jq -r '.container_port // 0' <<<"$session")" \
    --arg protocol "$(jq -r '.protocol // "http"' <<<"$session")" \
    --argjson command "$(jq -c '.command // []' <<<"$session")" \
    '{id:$id,snapshot:$snapshot,image:$image,name:$name,
      container_port:$container_port,protocol:$protocol,command:$command}' > "$body"
  if ! response="$(session_call "$worker" "/sessions/${id}/restore" "$body")"; then
    rm -f -- "$body"
    return 1
  fi
  rm -f -- "$body"
  # The target is running now, so the previous copy is no longer reachable
  # through the hub. Remove its container/record instead of leaking it.
  if [[ -n "$old_worker" && "$old_worker" != "$worker" ]]; then
    session_call "$old_worker" "/sessions/${id}/rm" >/dev/null 2>&1 \
      || beaut_warn "could not remove old session copy on $old_worker"
  fi
  host_port="$(jq -r '.host_port // 0' <<<"$response")"
  session="$(jq -c --arg ts "$(beaut_iso)" --arg worker "$worker" \
    --arg host "$(worker_host "$worker")" --argjson host_port "$host_port" \
    '.status="running" | .worker=$worker | .worker_host=$host |
     .host_port=$host_port | .updated_at=$ts' <<<"$session")"
  session_write "$id" "$session"
  session_refresh_route "$id" || true
  printf '%s\n' "$session"
}

session_move() {
  local id="$1" new_worker="$2" old_worker
  old_worker="$(jq -r '.worker' "$(session_path "$id")")" || return 1
  [[ "$old_worker" == "$new_worker" ]] && {
    beaut_warn "session already on $new_worker"
    return 0
  }
  session_snapshot "$id" >/dev/null || {
    beaut_warn "cannot snapshot before move"
    return 1
  }
  session_stop "$id" >/dev/null 2>&1 || true
  session_restore "$id" "$new_worker"
}

session_remove() {
  local id="$1" session worker
  session="$(session_get "$id")" || return 1
  worker="$(jq -r '.worker' <<<"$session")"
  session_call "$worker" "/sessions/${id}/rm" >/dev/null 2>&1 || true
  session_route_remove "$id"
  rm -f -- "$(session_path "$id")"
}

session_live_status() {
  local id="$1" session worker response
  session="$(session_get "$id")" || return 1
  worker="$(jq -r '.worker' <<<"$session")"
  response="$(session_call "$worker" "/sessions/${id}/status")" || return 1
  printf '%s\n' "$response"
}

# Run a command in the session container.  command_json must be a JSON array.
session_exec() {
  local id="$1" command_json="${2:-[]}" session worker body response result
  session="$(session_get "$id")" || return 1
  worker="$(jq -r '.worker // ""' <<<"$session")"
  [[ -n "$worker" ]] || return 1
  body="$(mktemp "${TMPDIR:-/tmp}/beaut-exec.XXXXXX")" || return 1
  jq -cn --argjson command "$command_json" '{command:$command}' > "$body" || {
    rm -f -- "$body"
    return 1
  }
  response="$(session_call "$worker" "/sessions/${id}/exec" "$body")"
  result=$?
  rm -f -- "$body"
  (( result == 0 )) || return "$result"
  printf '%s\n' "$response"
}
