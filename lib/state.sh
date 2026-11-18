# state.sh - tiny JSON state. One file per worker and one file per job.

state_init() {
  ensure_dir "$STATE_DIR/workers"
  ensure_dir "$STATE_DIR/jobs"
  ensure_dir "$STATE_DIR/heartbeat"
  ensure_dir "$STATE_DIR/assign"
  ensure_dir "$STATE_DIR/marks"
  ensure_dir "$SNAPSHOT_DIR"
  ensure_dir "$CONTAINER_DIR"
  ensure_dir "$WORKERS_DIR" 700
  ensure_dir "$KEYS_DIR" 700
}

state_worker_file() { printf '%s/workers/%s.json\n' "$STATE_DIR" "$1"; }
state_job_file() { printf '%s/jobs/%s.json\n' "$STATE_DIR" "$1"; }
state_heartbeat_file() { printf '%s/heartbeat/%s\n' "$STATE_DIR" "$1"; }

state_heartbeat_mark() {
  printf '%s\n' "$(now_epoch)" | atomic_write "$(state_heartbeat_file "$1")"
}

state_heartbeat_epoch() {
  local file value
  file="$(state_heartbeat_file "$1")"
  [[ -f "$file" ]] || return 1
  value="$(<"$file")"
  is_uint "$value" || return 1
  printf '%s\n' "$value"
}

state_worker_save() {
  local hash="$1" file
  is_hash "$hash" || return 1
  file="$(state_worker_file "$hash")"
  atomic_write "$file"
}

# state_workers_json - all reports with a computed online flag. A report older
# than DEATH_TIME is offline even if no delete happened.
state_workers_json() {
  local file hash now hb
  now="$(now_epoch)"
  for file in "$STATE_DIR"/workers/*.json; do
    [[ -f "$file" ]] || continue
    hash="$(basename -- "$file" .json)"
    hb="$(state_heartbeat_epoch "$hash" || printf 0)"
    jq -c --argjson now "$now" --argjson hb "$hb" --argjson death "$DEATH_TIME" '
      .last_seen = ([.last_seen // 0, $hb] | max)
      | .online = (($now - .last_seen) <= $death)
    ' "$file"
  done | jq -s 'sort_by(.hash)'
}

# job_create PROJECT ARCHIVE - stable id per project path, changing archive per
# build. A repeated run updates the archive and leaves the placement alone.
job_create() {
  local project="$1" archive="$2" id now file
  id="$(hash_text "$project")"
  now="$(now_epoch)"
  file="$(state_job_file "$id")"
  if [[ -f "$file" ]]; then
    jq --arg archive "$archive" --argjson now "$now" '
      if .archive == $archive then
        .updated_at = $now
      else
        .archive = $archive
        | .state = (
            if .primary == null then "pending"
            elif .state == "done" then "assigned"
            else .state
            end
          )
        | .updated_at = $now
      end
    ' "$file" | atomic_write "$file"
  else
    jq -cn --arg id "$id" --arg project "$project" --arg archive "$archive" \
      --argjson now "$now" \
      '{id:$id,project:$project,archive:$archive,state:"pending",
        primary:null,backup:null,snapshot:null,created:$now,updated_at:$now}' |
      atomic_write "$file"
  fi
  printf '%s\n' "$id"
}

job_load() {
  local file
  file="$(state_job_file "$1")"
  [[ -f "$file" ]] || return 1
  cat -- "$file"
}

job_get() {
  local value
  value="$(job_load "$1" | jq -r --arg key "$2" '.[$key] // empty')" || return 1
  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}

job_update() {
  local id="$1" file
  shift
  file="$(state_job_file "$id")"
  [[ -f "$file" ]] || return 1
  jq "$@" "$file" | atomic_write "$file"
}

job_list() {
  local file first=yes
  printf '['
  for file in "$STATE_DIR"/jobs/*.json; do
    [[ -f "$file" ]] || continue
    [[ "$first" == yes ]] || printf ','
    first=no
    cat -- "$file"
  done
  printf ']\n'
}

job_exists() {
  is_hash "${1:-}" || return 1
  [[ -f "$(state_job_file "$1")" ]]
}
