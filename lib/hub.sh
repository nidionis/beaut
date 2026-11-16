# hub.sh - inventory workers, cache state, answer requests and listen.

offline_worker() {
  local name="$1" host="$2" port="$3" via="$4" seen="$5" error="${6:-unreachable}"
  jq -cn \
    --arg name "$name" \
    --arg host "$host" \
    --argjson port "$port" \
    --arg via "$via" \
    --arg seen "$seen" \
    --arg error "$error" \
    '{name:$name,host:$host,port:$port,via:$via,online:false,last_seen:$seen,error:$error}'
}

# Print "via\nbody" for the first reachable worker endpoint.
probe_worker() {
  local host="$1" port="$2" tunnel="$3" reply urlhost="$1"
  [[ "$urlhost" == *:* && "$urlhost" != \[* ]] && urlhost="[$urlhost]"

  if [[ -n "$tunnel" ]] && reply="$(curl -fsS --noproxy '*' --connect-timeout 1 --max-time 2 \
    "http://127.0.0.1:${tunnel}/info" 2>/dev/null)"; then
    printf 'tunnel\n%s\n' "$reply"
    return 0
  fi
  if reply="$(curl -fsS --noproxy '*' --connect-timeout 1 --max-time 2 \
    "http://${urlhost}:${port}/info" 2>/dev/null)"; then
    printf 'direct\n%s\n' "$reply"
    return 0
  fi
  return 1
}

workers_json() {
  local now row name host port ssh tunnel reply via body obj
  local -a objects=()

  now="$(utc_now)"
  while IFS='|' read -r name host port ssh tunnel; do
    [[ -n "$name" ]] || continue
    is_uint "$port" || port=8090
    is_uint "$tunnel" || tunnel=""

    if reply="$(probe_worker "$host" "$port" "$tunnel")"; then
      via="${reply%%$'\n'*}"
      body="${reply#*$'\n'}"
      obj="$(jq -c \
        --arg name "$name" \
        --arg host "$host" \
        --argjson port "$port" \
        --arg via "$via" \
        --arg seen "$now" \
        -f "$BEAUT_ROOT/share/jq/worker.jq" <<<"$body" 2>/dev/null)" || obj=""
      if [[ -n "$obj" ]]; then
        objects+=("$obj")
      else
        objects+=("$(offline_worker "$name" "$host" "$port" "$via" "$now" "invalid status")")
      fi
    else
      objects+=("$(offline_worker "$name" "$host" "$port" "${tunnel:+tunnel}" "$now")")
    fi
  done < <(worker_rows)

  if (( ${#objects[@]} == 0 )); then
    printf '[]\n'
  else
    printf '%s\n' "${objects[@]}" | jq -s '.'
  fi
}

hub_json() {
  local hub now workers
  hub="$(node_name)"
  now="$(utc_now)"
  workers="$(workers_json)"
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$workers" || workers='[]'
  jq -cn --arg hub "$hub" --arg now "$now" --argjson workers "$workers" \
    '{hub:$hub,now:$now,workers:$workers}'
}

cache_workers() {
  local json="$1" tmp
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  tmp="$(mktemp "$STATE_DIR/.workers.XXXXXX" 2>/dev/null)" || return 0
  {
    printf 'name\tvia\tonline\tcpus\tload\tmem_available_kb\tmem_total_kb\tdisk_free_kb\tdisk_total_kb\tlast_seen\n'
    jq -r -f "$BEAUT_ROOT/share/jq/workers-tsv.jq" <<<"$json"
  } >"$tmp" 2>/dev/null && mv "$tmp" "$STATE_DIR/workers.tsv" || rm -f "$tmp"
}

dashboard() {
  local json="$1" hub now rows
  hub="$(jq -r '.hub' <<<"$json")"
  now="$(jq -r '.now' <<<"$json")"
  rows="$(jq -r -f "$BEAUT_ROOT/share/jq/dashboard-rows.jq" <<<"$json")"

  render_template "$BEAUT_ROOT/share/dashboard.html" \
    HUB "$hub" \
    NOW "$now" \
    ROWS "$rows"
}

handle_hub() {
  local json
  http_accept || return

  case "$HTTP_PATH" in
    /health)
      http_respond "200 OK" "text/plain" $'ok\n'
      ;;
    /status|/workers|/)
      json="$(hub_json)" || {
        http_respond "500 Internal Server Error" "text/plain" $'inventory probe failed\n'
        return
      }
      cache_workers "$json"
      if [[ "$HTTP_PATH" == /workers ]]; then
        http_respond "200 OK" "application/json" "$(jq -c '.workers' <<<"$json")"$'\n'
      elif [[ "$HTTP_PATH" == /status ]]; then
        http_respond "200 OK" "application/json" "$json"$'\n'
      else
        http_respond "200 OK" "text/html; charset=utf-8" "$(dashboard "$json")"
      fi
      ;;
    /favicon.ico)
      http_respond "204 No Content" "text/plain" ""
      ;;
    *)
      serve_site "$HTTP_PATH"
      ;;
  esac
}

serve_hub() {
  http_listen hub "$PORT" "$HUB_BIND" beaut-hub-http
}
