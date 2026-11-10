#!/usr/bin/env bash
# lib/services.sh — minimal service leases, route state and TCP listeners.
#
# Manifest (personal tree): $SVR_ROOT/service/<name>/ports
#   <public_port> <app_port>       one line per forwarded TCP port
#
# State (server): $SERVICE_DIRECTORY/<name>/
#   lease.tsv    worker <TAB> expires
#   routes.tsv   public <TAB> app
# Router state: $SERVICE_DIRECTORY/router/
#   <public>.pid, <public>.target, router.log
set -uo pipefail

SERVICES_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F has_command >/dev/null 2>&1; then
  . "$SERVICES_LIB_DIR/core.sh"
fi

service_validate_name() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
}

service_worker_valid() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

service_root() {
  printf '%s' "${SERVICE_DIRECTORY:-${STATE_DIR:?STATE_DIR is required}/services}"
}

service_directory() {
  printf '%s/%s' "$(service_root)" "${1:?missing service}"
}

service_manifest_directory() {
  printf '%s/service/%s' "${SVR_ROOT:-${HOME:?HOME is required}/.svr}" "${1:?missing service}"
}

service_file() {
  printf '%s/%s' "$(service_directory "$1")" "${2:?missing state file}"
}

service_lock() {
  local directory="$1"
  SERVICE_LOCK_FD=''
  mkdir -p -- "$directory" || return 1
  has_command flock || return 0
  exec {SERVICE_LOCK_FD}>"$directory/.lock" || return 1
  flock -w 5 "$SERVICE_LOCK_FD" || {
    exec {SERVICE_LOCK_FD}>&-
    SERVICE_LOCK_FD=''
    return 1
  }
}

service_unlock() {
  [[ -n "${SERVICE_LOCK_FD:-}" ]] || return 0
  exec {SERVICE_LOCK_FD}>&-
  SERVICE_LOCK_FD=''
}

service_ttl() {
  local ttl="${SERVICE_LEASE_SECONDS:-15}"
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=15
  printf '%s' "$ttl"
}

service_port_valid() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# Replace a state file atomically: the router may read it at any time.
service_write_atomic() {
  local file="$1" content="$2" temporary="$1.$$"
  printf '%s\n' "$content" > "$temporary" || {
    rm -f -- "$temporary"
    return 1
  }
  chmod 600 "$temporary" 2>/dev/null || true
  mv -f -- "$temporary" "$file"
}

# Print validated "<first> <TAB> <second>" rows from a two-column file.
service_read_ports() {
  local file="${1:?missing ports file}" first second ignored
  [[ -f "$file" ]] || return 1
  while read -r first second ignored; do
    [[ "$first" == '#'* ]] && continue
    service_port_valid "$first" && service_port_valid "$second" || continue
    printf '%s\t%s\n' "$first" "$second"
  done < "$file"
}

service_ports() {
  service_read_ports "$(service_manifest_directory "$1")/ports"
}

service_lease_read() {
  local name="$1" file owner expires
  file="$(service_file "$name" lease.tsv)"
  [[ -f "$file" ]] || return 1
  IFS=$'\t' read -r owner expires < "$file" || return 1
  [[ -n "$owner" && "$expires" =~ ^[0-9]+$ ]] || return 1
  printf '%s\t%s' "$owner" "$expires"
}

service_lease_write() {
  local name="$1" worker="$2" now ttl
  now="$(date +%s)"
  ttl="$(service_ttl)"
  service_write_atomic "$(service_file "$name" lease.tsv)" \
    "$(printf '%s\t%s' "$worker" "$((now + ttl))")"
}

service_claim() {
  local name="$1" worker="$2" directory routes lease owner expires now
  service_validate_name "$name" && service_worker_valid "$worker" || return 1
  routes="$(service_ports "$name")" || return 2
  [[ -n "$routes" ]] || return 2
  directory="$(service_directory "$name")"
  service_lock "$directory" || return 1
  now="$(date +%s)"
  if lease="$(service_lease_read "$name")"; then
    IFS=$'\t' read -r owner expires <<< "$lease"
    if (( expires > now )) && [[ "$owner" != "$worker" ]]; then
      service_unlock
      return 3
    fi
  fi
  if ! service_lease_write "$name" "$worker" \
     || ! service_write_atomic "$directory/routes.tsv" "$routes"; then
    service_unlock
    return 1
  fi
  service_unlock
}

service_heartbeat() {
  local name="$1" worker="$2" directory lease owner
  service_validate_name "$name" && service_worker_valid "$worker" || return 1
  directory="$(service_directory "$name")"
  service_lock "$directory" || return 1
  if ! lease="$(service_lease_read "$name")"; then
    service_unlock
    return 3
  fi
  IFS=$'\t' read -r owner _ <<< "$lease"
  [[ "$owner" == "$worker" ]] || { service_unlock; return 3; }
  if ! service_lease_write "$name" "$worker"; then
    service_unlock
    return 1
  fi
  service_unlock
}

service_release() {
  local name="$1" worker="$2" directory lease owner
  service_validate_name "$name" && service_worker_valid "$worker" || return 1
  directory="$(service_directory "$name")"
  service_lock "$directory" || return 1
  if lease="$(service_lease_read "$name")"; then
    IFS=$'\t' read -r owner _ <<< "$lease"
    [[ "$owner" == "$worker" ]] && rm -f -- "$directory/lease.tsv" "$directory/routes.tsv"
  fi
  service_unlock
}

service_status() {
  local name="$1" directory lease owner expires public app
  service_validate_name "$name" || return 1
  directory="$(service_directory "$name")"
  lease="$(service_lease_read "$name")" || return 1
  IFS=$'\t' read -r owner expires <<< "$lease"
  printf 'worker=%s\nexpires=%s\n' "$owner" "$expires"
  [[ -f "$directory/routes.tsv" ]] || return 0
  while IFS=$'\t' read -r public app; do
    printf 'route=%s:%s\n' "$public" "$app"
  done < "$directory/routes.tsv"
}

# Shell command served by GET /service/<name>/run.
service_run_command() {
  local name="$1" url
  url="http://${SERVER_HOST:?SERVER_HOST is required}:${HTTP_PORT:?HTTP_PORT is required}"
  printf "#!/bin/sh\ncurl -fsS '%s/scripts/service_worker.sh' | env BEAUT_URL='%s' SERVICE_SSH='%s@%s' SERVICE_SSH_PORT='%s' bash -s -- '%s'" \
    "$url" "$url" "${SERVICE_USER:-beaut}" "$SERVER_HOST" "${SERVICE_SSH_PORT:-}" "$name"
}

# Print active "<public> <TAB> <worker>:<app>" rows.
service_active_routes() {
  local root lease directory owner expires now public app
  root="$(service_root)"
  now="$(date +%s)"
  for lease in "$root"/*/lease.tsv; do
    [[ -f "$lease" ]] || continue
    directory="${lease%/*}"
    IFS=$'\t' read -r owner expires < "$lease" || continue
    [[ "$expires" =~ ^[0-9]+$ ]] || continue
    (( expires > now )) || continue
    [[ -f "$directory/routes.tsv" ]] || continue
    while IFS=$'\t' read -r public app; do
      printf '%s\t%s:%s\n' "$public" "$owner" "$app"
    done < <(service_read_ports "$directory/routes.tsv")
  done
}

service_router_pid_ok() {
  local pid="$1" public="$2"
  [[ -r "/proc/$pid/cmdline" ]] || return 1
  tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q "TCP-LISTEN:$public,"
}

service_router_stop_one() {
  local pidfile="$1" router="${1%/*}" public pid
  public="${pidfile##*/}"; public="${public%.pid}"
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && service_router_pid_ok "$pid" "$public"; then
    kill "$pid" 2>/dev/null || true
  fi
  rm -f -- "$pidfile" "$router/$public.target"
}

service_router_start() {
  local router="$1" public="$2" target="$3"
  printf '%s\n' "$target" > "$router/$public.target"
  socat "TCP-LISTEN:$public,fork,reuseaddr" "TCP:$target" >> "$router/router.log" 2>&1 &
  printf '%s\n' "$!" > "$router/$public.pid"
}

service_router_stop() {
  local pidfile
  for pidfile in "$(service_root)"/router/*.pid; do
    [[ -f "$pidfile" ]] || continue
    service_router_stop_one "$pidfile"
  done
}

service_router_sync() {
  local router pidfile public target pid old_target
  local -A wanted=()
  router="$(service_root)/router"
  mkdir -p -- "$router"

  while IFS=$'\t' read -r public target; do
    wanted["$public"]="$target"
  done < <(service_active_routes)

  for public in "${!wanted[@]}"; do
    target="${wanted[$public]}"
    pidfile="$router/$public.pid"
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    old_target="$(cat "$router/$public.target" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && service_router_pid_ok "$pid" "$public" \
       && [[ "$old_target" == "$target" ]]; then
      continue
    fi
    service_router_stop_one "$pidfile"
    service_router_start "$router" "$public" "$target"
  done

  for pidfile in "$router"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    public="${pidfile##*/}"; public="${public%.pid}"
    [[ -n "${wanted[$public]:-}" ]] && continue
    service_router_stop_one "$pidfile"
  done
}
