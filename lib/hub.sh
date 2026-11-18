# hub.sh - the hub: status, worker reports, work scripts and container files.

hub_hash_valid() { is_hex "${1:-}" && [[ ${#1} -eq 16 ]]; }

# hub_ranked_workers - online workers above the minimums, in SCHEDULING_PRIO
# order. Higher free resources first; load1 is the lazy tie-break.
hub_ranked_workers() {
  local prio
  prio="$(scheduling_prio_json)"
  state_workers_json | jq --argjson prio "$prio" \
    --argjson min_cpu "$MIN_CPU" \
    --argjson min_ram "$MIN_RAM_KB" \
    --argjson min_disk "$MIN_DISK_KB" '
    def free($p):
      if $p == "cpu" then -((.resources.cpus // 0) - (.resources.load1 // 0))
      elif $p == "ram" then -(.resources.mem_available_kb // 0)
      elif $p == "disk" then -(.resources.disk_free_kb // 0)
      else 0 end;
    [ .[]
      | select(.online == true)
      | select((.resources.cpus // 0) >= $min_cpu)
      | select((.resources.mem_available_kb // 0) >= $min_ram)
      | select((.resources.disk_free_kb // 0) >= $min_disk)
    ]
    | sort_by(([ $prio[] as $p | free($p) ] + [ .resources.load1 // 0 ]))
  '
}

hub_worker_hash() {
  local workers="$1" index="${2:-0}"
  jq -r --argjson i "$index" '.[$i].hash // empty' <<<"$workers"
}

hub_worker_field() {
  local workers="$1" hash="$2" field="$3"
  jq -r --arg hash "$hash" --arg field "$field" '
    .[] | select(.hash == $hash) | .[$field] // empty
  ' <<<"$workers"
}

# hub_refresh_jobs - a job whose primary stopped heartbeating returns to the
# pending queue. Its snapshot is kept so the next worker can restore it.
hub_refresh_jobs() {
  local workers now job_file id primary backup online candidate backup_pick
  workers="$(hub_ranked_workers)"
  now="$(now_epoch)"

  for job_file in "$STATE_DIR"/jobs/*.json; do
    [[ -f "$job_file" ]] || continue
    id="$(jq -r '.id' "$job_file")"
    primary="$(jq -r '.primary // empty' "$job_file")"
    backup="$(jq -r '.backup // empty' "$job_file")"
    [[ "$(jq -r '.state // ""' "$job_file")" == done ]] && continue

    if [[ -n "$primary" ]] &&
      ! jq -e --arg h "$primary" 'any(.[]; .hash == $h)' <<<"$workers" >/dev/null; then
      jq --argjson now "$now" '
        .state = "pending" | .primary = null | .updated_at = $now
      ' "$job_file" | atomic_write "$job_file"
      primary=""
    fi

    [[ -n "$primary" ]] || continue
    if [[ -z "$backup" ]] ||
      ! jq -e --arg h "$backup" 'any(.[]; .hash == $h)' <<<"$workers" >/dev/null; then
      backup_pick="$(jq -r --arg h "$primary" '[.[] | .hash | select(. != $h)][0] // empty' <<<"$workers")"
      jq --arg backup "$backup_pick" --argjson now "$now" '
        .backup = (if $backup == "" then null else $backup end)
        | .updated_at = $now
      ' "$job_file" | atomic_write "$job_file"
    fi
  done
}

# hub_claim_job HASH - give the first pending job to HASH, but only if HASH is
# the best online candidate. This is the whole scheduler.
hub_claim_job() {
  local hash="$1" workers best backup job_file id
  workers="$(hub_ranked_workers)"
  best="$(hub_worker_hash "$workers" 0)"
  [[ "$best" == "$hash" ]] || return 1

  for job_file in "$STATE_DIR"/jobs/*.json; do
    [[ -f "$job_file" ]] || continue
    [[ "$(jq -r '.state' "$job_file")" == pending ]] || continue
    id="$(jq -r '.id' "$job_file")"
    backup="$(jq -r --arg h "$hash" '[.[] | .hash | select(. != $h)][0] // empty' <<<"$workers")"
    jq --arg primary "$hash" --arg backup "$backup" --argjson now "$(now_epoch)" '
      .state = "assigned"
      | .primary = $primary
      | .backup = (if $backup == "" then null else $backup end)
      | .updated_at = $now
    ' "$job_file" | atomic_write "$job_file"
    printf '%s\n' "$id"
    return 0
  done
  return 1
}

hub_snapshot_url() {
  local job="$1" workers snapshot_worker backup address port
  job_load "$job" | jq -e '.snapshot != null' >/dev/null || return 1
  snapshot_worker="$(job_load "$job" | jq -r '.snapshot.worker // empty')"
  backup="$(job_load "$job" | jq -r '.backup // empty')"
  workers="$(state_workers_json)"
  if [[ -z "$snapshot_worker" ]] ||
    ! jq -e --arg h "$snapshot_worker" \
      'any(.[]; .hash == $h and .online == true)' <<<"$workers" >/dev/null; then
    snapshot_worker="$backup"
  fi
  [[ -n "$snapshot_worker" ]] || return 1
  jq -e --arg h "$snapshot_worker" \
    'any(.[]; .hash == $h and .online == true)' <<<"$workers" >/dev/null || return 1
  address="$(hub_worker_field "$workers" "$snapshot_worker" address)"
  port="$(hub_worker_field "$workers" "$snapshot_worker" port)"
  [[ -n "$address" && -n "$port" ]] || return 1
  api_url "$address" "$port" "/snapshot/latest?job=$job"
}

# hub_pack_project FOLDER - cache one container project and create its job.
hub_pack_project() {
  local source="$1" canonical name temp stage id archive
  canonical="$(readlink -f -- "$source")" || die "missing project: $source"
  [[ -d "$canonical" ]] || die "not a directory: $source"
  name="$(basename -- "$canonical")"
  id="$(hash_text "$canonical")"
  ensure_dir "$CONTAINER_DIR"
  stage="$CONTAINER_DIR/.pack.$$"
  temp="$CONTAINER_DIR/.pack.$$.tar.gz"
  mkdir -p "$stage/$id"
  tar -C "$canonical" -cf - \
    --exclude='./.git' --exclude='./.git/*' \
    --exclude='./.idea' --exclude='./.idea/*' \
    --exclude='./.beaut-archive' --exclude='./.incoming*' . |
    tar -C "$stage/$id" -xf - ||
    { rm -rf -- "$stage" "$temp"; die "cannot pack project: $source"; }
  tar -czf "$temp" -C "$stage" "$id" ||
    { rm -rf -- "$stage" "$temp"; die "cannot pack project: $source"; }
  rm -rf -- "$stage"
  archive="$(hash_file "$temp")"
  mv -f -- "$temp" "$CONTAINER_DIR/$archive.tar.gz"
  job_create "$canonical" "$archive" >/dev/null
  printf '%s\n' "$id"
}

hub_job_script() {
  local job="$1" workers backup backup_address="" backup_port="" restore_url=""
  local archive container_url
  workers="$(hub_ranked_workers)"
  backup="$(job_get "$job" backup || true)"
  archive="$(job_get "$job" archive)"
  container_url="$(api_url "$HUB" "$PORT" "/container/$archive.tar.gz")"
  restore_url="$(hub_snapshot_url "$job" || true)"

  if [[ -n "${backup:-}" ]]; then
    backup_address="$(hub_worker_field "$workers" "$backup" address)"
    backup_port="$(hub_worker_field "$workers" "$backup" port)"
  fi

  render_template "$BEAUT_ROOT/share/templates/work-job.sh" \
    JOB "$(sh_quote "$job")" \
    ARCHIVE "$(sh_quote "$archive")" \
    CONTAINER_URL "$(sh_quote "$container_url")" \
    RESTORE_URL "$(sh_quote "$restore_url")" \
    BACKUP_ADDRESS "$(sh_quote "$backup_address")" \
    BACKUP_PORT "$(sh_quote "$backup_port")"
}

hub_work() {
  local hash job script=""
  hash="$(http_query_get hash || true)"
  hub_hash_valid "$hash" || {
    http_respond "200 OK" "text/x-shellscript" $':\n'
    return
  }

  hub_refresh_jobs
  hub_claim_job "$hash" >/dev/null || true

  while IFS= read -r job; do
    [[ -n "$job" ]] || continue
    script+="$(hub_job_script "$job")"$'\n'
  done < <(job_list | jq -r --arg hash "$hash" \
    '.[] | select(.primary == $hash and .state != "done") | .id')

  if [[ -z "$script" ]]; then
    http_respond "200 OK" "text/x-shellscript" $':\n'
  else
    http_respond "200 OK" "text/x-shellscript" "$script"
  fi
}

hub_report() {
  local file="${HTTP_BODY_FILE:-}" hash now iso job_primary job_backup job_snapshot_worker
  local job_id job_state report_archive current_archive snap_id snap_path snap_time
  [[ "$HTTP_METHOD" == POST ]] || {
    http_respond "405 Method Not Allowed" "text/plain" $'POST required\n'
    return
  }
  [[ -n "$file" && -s "$file" ]] && jq -e . "$file" >/dev/null 2>&1 || {
    http_respond "400 Bad Request" "text/plain" $'report is not JSON\n'
    return
  }

  hash="$(jq -r '.hash // empty' "$file")"
  hub_hash_valid "$hash" || {
    http_respond "400 Bad Request" "text/plain" $'invalid worker hash\n'
    return
  }

  now="$(now_epoch)"
  iso="$(utc_now)"
  jq --argjson now "$now" --arg iso "$iso" '
    .last_seen = $now | .last_seen_iso = $iso | .online = true
  ' "$file" | state_worker_save "$hash"

  while IFS=$'\t' read -r job_id job_state report_archive; do
    hub_hash_valid "$job_id" || continue
    job_exists "$job_id" || continue
    job_primary="$(job_load "$job_id" | jq -r '.primary // empty')"
    [[ -z "$job_primary" || "$job_primary" == "$hash" ]] || continue
    current_archive="$(job_get "$job_id" archive)"
    [[ "$report_archive" == "$current_archive" ]] || continue
    case "$job_state" in
      running|done)
        job_update "$job_id" --arg state "$job_state" --argjson now "$now" \
          '.state = $state | .updated_at = $now'
        ;;
      failed|stopped)
        job_update "$job_id" --argjson now "$now" \
          '.state = "pending" | .primary = null | .updated_at = $now'
        ;;
    esac
  done < <(jq -r '.jobs[]? | [(.id // ""), (.state // "running"), (.archive // "")] | @tsv' "$file")

  while IFS=$'\t' read -r snap_id snap_path snap_time; do
    hub_hash_valid "$snap_id" || continue
    job_exists "$snap_id" || continue
    job_backup="$(job_load "$snap_id" | jq -r '.backup // empty')"
    job_snapshot_worker="$(job_load "$snap_id" | jq -r '.snapshot.worker // empty')"
    if [[ "$hash" != "$job_backup" && -n "$job_snapshot_worker" &&
      "$job_snapshot_worker" == "$job_backup" ]]; then
      continue
    fi
    jq --arg path "$snap_path" --arg time "$snap_time" --arg worker "$hash" \
      --argjson now "$now" '
      .snapshot = {path:$path,time:$time,worker:$worker} | .updated_at = $now
    ' "$(state_job_file "$snap_id")" | atomic_write "$(state_job_file "$snap_id")"
  done < <(jq -r '.snapshots[]? | [(.job // ""), (.path // ""), (.time // "")] | @tsv' "$file")

  http_respond "200 OK" "text/plain" $'ok\n'
}

hub_heartbeat() {
  local hash address port
  [[ "$HTTP_METHOD" == POST ]] || {
    http_respond "405 Method Not Allowed" "text/plain" $'POST required\n'
    return
  }
  hash="$(http_param hash || true)"
  address="$(http_param address || true)"
  port="$(http_param port || true)"
  hub_hash_valid "$hash" || {
    http_respond "400 Bad Request" "text/plain" $'invalid worker hash\n'
    return
  }
  state_heartbeat_mark "$hash"
  if ! [[ -f "$(state_worker_file "$hash")" ]] && [[ -n "$address" ]]; then
    jq -cn --arg hash "$hash" --arg address "$address" --argjson port "${port:-0}" \
      --argjson now "$(now_epoch)" \
      '{hash:$hash,address:$address,port:$port,last_seen:$now,online:true,
        resources:{},jobs:[],snapshots:[]}' | state_worker_save "$hash"
  fi
  http_respond "200 OK" "text/plain" $'ok\n'
}

hub_status() {
  hub_refresh_jobs || true
  jq -cn --arg hub "$HUB" --arg now "$(utc_now)" \
    --argjson workers "$(state_workers_json)" \
    --argjson jobs "$(job_list)" \
    '{hub:$hub,now:$now,workers:$workers,jobs:$jobs}'
}

hub_health() { http_respond "200 OK" "text/plain" $'ok\n'; }

hub_container() {
  local name archive file
  name="${HTTP_PATH#/container/}"
  name="${name%.tar.gz}"
  [[ "$name" != */* && -n "$name" ]] || { http_not_found; return; }
  archive="$name"
  if [[ ! -f "$CONTAINER_DIR/$archive.tar.gz" ]] && hub_hash_valid "$name" && job_exists "$name"; then
    archive="$(job_get "$name" archive || true)"
  fi
  file="$CONTAINER_DIR/$archive.tar.gz"
  [[ -f "$file" ]] || { http_not_found; return; }
  http_send_file "$file" "application/gzip"
}

hub_route() {
  case "$HTTP_PATH" in
    /container/*) hub_container ;;
    *) serve_site "$HTTP_PATH" ;;
  esac
}

handle_hub() {
  http_dispatch hub_route
}

serve_hub() {
  state_init
  http_listen hub "$PORT" "$HUB_BIND" beaut-hub-http
}

work_route() {
  case "$HTTP_PATH" in
    /health) hub_health ;;
    *) serve_work "$HTTP_PATH" ;;
  esac
}

handle_work() {
  http_dispatch work_route
}

serve_work_port() {
  state_init
  http_listen work "$WORK_PORT" "$WORK_BIND" beaut-work-http
}
