#!/usr/bin/env bash
# workers.sh - configured worker registry and live capability queries.
# Configuration is the source of truth; no database is required.

worker_rows() {
  local row
  for row in "${BEAUT_WORKERS[@]:-}"; do
    [[ -n "$row" ]] || continue
    [[ "$row" == \#* ]] && continue
    printf '%s\n' "$row"
  done
}

worker_rows_for_hub() {
  local wanted_hub="${1:-}" row name host port hub weight
  local -a preferred=() rest=()
  while IFS='|' read -r name host port hub weight; do
    [[ -n "$name" ]] || continue
    if [[ -n "$wanted_hub" && "$hub" == "$wanted_hub" ]]; then
      preferred+=("$name|$host|$port|$hub|${weight:-100}")
    else
      rest+=("$name|$host|$port|$hub|${weight:-100}")
    fi
  done < <(worker_rows)
  printf '%s\n' "${preferred[@]:-}" "${rest[@]:-}" | sed '/^$/d'
}

worker_find() {
  local wanted="${1:-}" row name host port hub weight
  while IFS='|' read -r name host port hub weight; do
    if [[ "$name" == "$wanted" ]]; then
      printf '%s|%s|%s|%s|%s\n' "$name" "$host" "$port" "$hub" "${weight:-100}"
      return 0
    fi
  done < <(worker_rows)
  return 1
}

worker_host() {
  local row host port
  row="$(worker_find "$1")" || return 1
  IFS='|' read -r _ host port _ _ <<<"$row"
  printf '%s' "$host"
}

worker_port() {
  local row host port
  row="$(worker_find "$1")" || return 1
  IFS='|' read -r _ host port _ _ <<<"$row"
  printf '%s' "$port"
}

worker_url() {
  local host port
  host="$(worker_host "$1")" || return 1
  port="$(worker_port "$1")" || return 1
  printf 'http://%s:%s' "$host" "$port"
}

worker_info() {
  local name="$1" url
  url="$(worker_url "$name")" || return 1
  curl -fsS --connect-timeout 2 --max-time 4 "$url/info" 2>/dev/null
}

worker_online() {
  worker_info "$1" >/dev/null 2>&1
}

worker_resources_json() {
  local cpus="${BEAUT_WORKER_CPUS:-}" memory="${BEAUT_WORKER_MEMORY_MB:-}"
  local disk="${BEAUT_WORKER_DISK_MB:-}" tags="${BEAUT_WORKER_TAGS:-}"
  local max_sessions="${BEAUT_WORKER_MAX_SESSIONS}"
  local load=""
  [[ -r /proc/loadavg ]] && load="$(awk '{print $1}' /proc/loadavg)"
  jq -cn \
    --arg name "${BEAUT_WORKER_NAME}" \
    --arg host "${BEAUT_WORKER_ADVERTISE}" \
    --argjson port "${BEAUT_WORKER_PORT}" \
    --arg cpus "$cpus" \
    --arg memory_mb "$memory" \
    --arg disk_mb "$disk" \
    --arg tags "$tags" \
    --arg load "$load" \
    --argjson max_sessions "$max_sessions" \
    --argjson sessions "$(worker_local_session_count)" \
    '{name:$name,host:$host,port:$port,resources:
      {cpus:($cpus|tonumber? // null),
       memory_mb:($memory_mb|tonumber? // null),
       disk_mb:($disk_mb|tonumber? // null),
       tags:($tags|split(",")|map(select(length>0))),
       max_sessions:$max_sessions,
       load:($load|tonumber? // null)},
      sessions:{running:$sessions}}'
}

worker_local_session_count() {
  local count=0 file
  shopt -s nullglob
  for file in "$BEAUT_STATE_DIR"/sessions/*.json; do
    [[ -f "$file" ]] || continue
    [[ "$(jq -r '.status // ""' "$file" 2>/dev/null)" == "running" ]] && count=$((count + 1))
  done
  shopt -u nullglob
  printf '%s' "$count"
}

workers_json() {
  local row name host port hub weight info
  local -a objects=()
  while IFS='|' read -r name host port hub weight; do
    [[ -n "$name" ]] || continue
    info="$(worker_info "$name" 2>/dev/null || true)"
    if [[ -n "$info" ]] && jq -e . >/dev/null 2>&1 <<<"$info"; then
      objects+=("$(jq -c --arg host "$host" --arg hub "$hub" --arg weight "${weight:-100}" \
        '. + {configured:{host:$host,preferred_hub:$hub,weight:($weight|tonumber? // 100)}, online:true}' <<<"$info")")
    else
      objects+=("$(jq -cn --arg name "$name" --arg host "$host" --argjson port "$port" \
        --arg hub "$hub" --arg weight "${weight:-100}" \
        '{name:$name,host:$host,port:$port,online:false,
          configured:{host:$host,preferred_hub:$hub,weight:($weight|tonumber? // 100)}}')")
    fi
  done < <(worker_rows)
  if (( ${#objects[@]} == 0 )); then
    printf '[]\n'
  else
    printf '%s\n' "${objects[@]}" | jq -s '.'
  fi
}

worker_choose() {
  local preferred_hub="${1:-${BEAUT_HUB_NAME}}" row name host port hub weight info running max
  while IFS='|' read -r name host port hub weight; do
    [[ -n "$name" ]] || continue
    info="$(worker_info "$name" 2>/dev/null || true)"
    [[ -n "$info" ]] || continue
    running="$(jq -r '.sessions.running // 0' <<<"$info")"
    max="$(jq -r '.resources.max_sessions // 1' <<<"$info")"
    if (( running < max )); then
      printf '%s\n' "$name"
      return 0
    fi
  done < <(worker_rows_for_hub "$preferred_hub")
  return 1
}
