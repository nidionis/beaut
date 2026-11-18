# worker.sh - one loop: heartbeat, report, pull work, snapshot.

worker_identity() {
  ensure_dir "$KEYS_DIR" 700
  if [[ ! -f "$NODE_KEY" ]]; then
    if mkdir "$KEYS_DIR/.key-lock" 2>/dev/null; then
      ssh-keygen -q -t ed25519 -N '' -f "$NODE_KEY" </dev/null || true
      rmdir "$KEYS_DIR/.key-lock" 2>/dev/null || true
    else
      local i
      for i in {1..50}; do
        [[ -f "$NODE_KEY.pub" ]] && break
        pause 0.1
      done
    fi
  fi
  [[ -f "$NODE_KEY.pub" ]] || die "cannot create worker key"
  NODE_HASH="$(worker_hash "$NODE_KEY.pub")"
  [[ -n "$NODE_HASH" ]] || die "cannot read worker hash"
  [[ -n "$NODE_ADDRESS" ]] || die "NODE_ADDRESS is empty"
  is_uint "$WORKER_PORT" || die "invalid WORKER_PORT: $WORKER_PORT"
}

worker_jobs_json() {
  local file job state archive first=yes
  printf '['
  for file in "$STATE_DIR"/marks/*.done "$STATE_DIR"/marks/*.running; do
    [[ -f "$file" ]] || continue
    job="$(basename -- "$file")"
    state="${job##*.}"
    job="${job%.*}"
    [[ "$state" == running && -f "$STATE_DIR/marks/$job.done" ]] && continue
    archive="$(cat -- "$file" 2>/dev/null || true)"
    is_hash "$archive" || archive=""
    [[ "$first" == yes ]] || printf ','
    first=no
    jq -cn --arg id "$job" --arg state "$state" --arg archive "$archive" \
      '{id:$id,state:$state,archive:$archive}'
  done
  printf ']\n'
}

worker_snapshot_latest() {
  local job="$1" file latest=""
  for file in "$SNAPSHOT_DIR/$job"/*.tar.gz "$SNAPSHOT_DIR/incoming/$job"/*.tar.gz; do
    [[ -f "$file" ]] || continue
    if [[ -z "$latest" || "$file" -nt "$latest" ]]; then
      latest="$file"
    fi
  done
  [[ -n "$latest" ]] || return 1
  printf '%s\n' "$latest"
}

worker_snapshots_json() {
  local dir job file first=yes
  printf '['
  for dir in "$SNAPSHOT_DIR"/* "$SNAPSHOT_DIR"/incoming/*; do
    [[ -d "$dir" ]] || continue
    job="$(basename -- "$dir")"
    [[ "$job" == incoming ]] && continue
    file="$(worker_snapshot_latest "$job" 2>/dev/null || true)"
    [[ -n "$file" ]] || continue
    [[ "$first" == yes ]] || printf ','
    first=no
    jq -cn --arg job "$job" --arg path "$file" \
      --arg time "$(TZ=UTC date -r "$file" +%Y-%m-%dT%H:%M:%SZ)" \
      '{job:$job,path:$path,time:$time}'
  done
  printf ']\n'
}

worker_report() {
  local body
  body="$(jq -cn \
    --arg hash "$NODE_HASH" \
    --arg address "$NODE_ADDRESS" \
    --argjson port "$WORKER_PORT" \
    --argjson resources "$(resources_json)" \
    --argjson packages "$(packages_json)" \
    --argjson jobs "$(worker_jobs_json)" \
    --argjson snapshots "$(worker_snapshots_json)" \
    '{hash:$hash,address:$address,port:$port,resources:$resources,
      packages:$packages,jobs:$jobs,snapshots:$snapshots}')"

  curl --noproxy '*' --silent --show-error --fail --max-time 30 \
    -X POST -H 'Content-Type: application/json' \
    --data-binary "$body" "$(api_url "$HUB" "$PORT" /report)" >/dev/null
}

worker_heartbeat() {
  curl --noproxy '*' --silent --show-error --fail --max-time 10 \
    -X POST --data "hash=$NODE_HASH&address=$NODE_ADDRESS&port=$WORKER_PORT" \
    "$(api_url "$HUB" "$PORT" /heartbeat)" >/dev/null
}

worker_pull_work() {
  local script
  script="$(curl --noproxy '*' --silent --show-error --fail --max-time 60 \
    "$(api_url "$HUB" "$WORK_PORT" "/work?hash=$NODE_HASH")")" || return 1
  [[ -n "$script" ]] || return 0
  export BEAUT_STATE_DIR="$STATE_DIR"
  export BEAUT_CONTAINER_DIR="$CONTAINER_DIR"
  export BEAUT_DOCKER_CMD="$DOCKER_CMD"
  printf '%s\n' "$script" | sh
}

worker_snapshot_create() {
  local job="$1" jobdir dest stamp
  jobdir="$CONTAINER_DIR/$job"
  [[ -d "$jobdir" ]] || return 1
  stamp="$(utc_stamp)"
  ensure_dir "$SNAPSHOT_DIR/$job"
  dest="$SNAPSHOT_DIR/$job/$stamp-$$.tar.gz"

  if [[ -f "$jobdir/snapshot.sh" ]]; then
    (cd -- "$jobdir" && bash ./snapshot.sh) >"$dest"
  else
    tar -czf "$dest" -C "$CONTAINER_DIR" \
      --exclude='.git' --exclude='.git/*' "$job"
  fi
  [[ -s "$dest" ]] || { rm -f -- "$dest"; return 1; }
  printf '%s\n' "$dest"
}

worker_snapshot_retain_dir() {
  local dir="$1" count=0 file
  [[ -d "$dir" ]] || return 0
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    count=$((count + 1))
    if (( count > RETAIN_SNAPSHOTS )); then
      rm -f -- "$file"
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name '*.tar.gz' \
    -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk '{ $1=""; sub(/^ /, ""); print }')
}

worker_snapshot_retain() {
  worker_snapshot_retain_dir "$SNAPSHOT_DIR/$1"
}

worker_backup_job() {
  local job="$1" target address port archive url
  target="$(cat "$STATE_DIR/assign/$job" 2>/dev/null || true)"
  read -r address port <<<"$target"
  archive="$(worker_snapshot_create "$job")" || return 1
  worker_snapshot_retain "$job"
  [[ -n "$address" && -n "$port" ]] || return 0
  [[ "$address" == "$NODE_ADDRESS" && "$port" == "$WORKER_PORT" ]] && return 0
  url="$(api_url "$address" "$port" "/snapshot?hash=$NODE_HASH&job=$job")"
  log "backup $job -> $address:$port"
  curl --noproxy '*' --silent --show-error --fail --max-time 600 \
    -X PUT --data-binary "@$archive" "$url" >/dev/null
}

worker_backup_all() {
  local file job
  for file in "$STATE_DIR"/assign/*; do
    [[ -f "$file" ]] || continue
    job="$(basename -- "$file")"
    worker_backup_job "$job" || warn "backup failed: $job"
  done
}

worker_snapshot_receive() {
  local hash job stamp dir dest
  hash="$(http_param hash || true)"
  job="$(http_param job || true)"
  is_hash "$hash" || {
    http_respond "400 Bad Request" "text/plain" $'invalid sender hash\n'
    return
  }
  is_hash "$job" || {
    http_respond "400 Bad Request" "text/plain" $'invalid job id\n'
    return
  }
  [[ -n "${HTTP_BODY_FILE:-}" && -s "$HTTP_BODY_FILE" ]] || {
    http_respond "400 Bad Request" "text/plain" $'empty snapshot\n'
    return
  }
  stamp="$(utc_stamp)"
  dir="$SNAPSHOT_DIR/incoming/$job"
  ensure_dir "$dir"
  dest="$dir/$stamp-$$.tar.gz"
  mv -- "$HTTP_BODY_FILE" "$dest"
  HTTP_BODY_FILE=""
  worker_snapshot_retain_dir "$dir"
  sync 2>/dev/null || true
  http_json "200 OK" "$(jq -cn --arg job "$job" --arg path "$dest" \
    '{ok:true,job:$job,path:$path}')"
}

worker_snapshot_http() {
  local job file
  job="$(http_query_get job || true)"
  is_hash "$job" || { http_not_found; return; }
  file="$(worker_snapshot_latest "$job" 2>/dev/null || true)"
  [[ -n "$file" ]] || { http_not_found; return; }
  http_send_file "$file" "application/gzip"
}

worker_route() {
  case "$HTTP_PATH" in
    /health) http_respond "200 OK" "text/plain" $'ok\n' ;;
    /snapshot) worker_snapshot_receive ;;
    /snapshot/latest) worker_snapshot_http ;;
    /status)
      http_json "200 OK" "$(jq -cn --arg hash "$NODE_HASH" --arg address "$NODE_ADDRESS" \
        --argjson port "$WORKER_PORT" --argjson resources "$(resources_json)" \
        --argjson jobs "$(worker_jobs_json)" --argjson snapshots "$(worker_snapshots_json)" \
        '{hash:$hash,address:$address,port:$port,resources:$resources,jobs:$jobs,snapshots:$snapshots}')"
      ;;
    *) http_not_found ;;
  esac
}

handle_worker() {
  worker_identity
  http_dispatch worker_route
}

serve_worker() {
  worker_identity
  state_init
  http_listen worker "$WORKER_PORT" "$WORKER_BIND" beaut-worker-http
}

# worker_listen_start - start the snapshot receiver beside the loop. One
# process owns both so the basic worker service needs only one unit.
worker_listen_start() {
  need socat
  socat "TCP-LISTEN:${WORKER_PORT},bind=${WORKER_BIND},fork,reuseaddr" \
    "EXEC:${BEAUT_ROOT}/bin/beaut-worker-http" &
  WORKER_LISTENER_PID=$!
  log "worker listening on ${WORKER_BIND}:${WORKER_PORT}"
}

worker_heartbeat_loop() {
  while :; do
    worker_heartbeat || true
    pause "$HEARTBEAT_DELAY"
  done
}

worker_loop() {
  local next_report next_backup now
  worker_identity
  state_init
  worker_listen_start
  worker_heartbeat_loop &
  WORKER_HEARTBEAT_PID=$!
  trap 'exit 0' INT TERM
  trap 'kill "$WORKER_LISTENER_PID" "$WORKER_HEARTBEAT_PID" 2>/dev/null || true' EXIT
  next_report=0
  next_backup=0

  while :; do
    now="$(now_epoch)"
    if (( now >= next_report )); then
      worker_report || warn "report failed"
      worker_pull_work || warn "work failed"
      next_report=$(( now + REPORT_DELAY ))
    fi
    if (( now >= next_backup )); then
      worker_backup_all || true
      next_backup=$(( now + BACKUP_DELAY ))
    fi
    pause "$HEARTBEAT_DELAY"
  done
}
