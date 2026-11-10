#!/usr/bin/env bash
# lib/services.sh — minimal service leases, route state and TCP listeners.
#
# Manifest (personal tree): $SVR_ROOT/service/<name>/ports
#   <public_port> <app_port>       one line per forwarded TCP port
#
# State (server): $SERVICE_DIRECTORY/<name>/
#   lease.tsv    worker <TAB> expires
#   routes.tsv   public <TAB> app
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

service_ports() {
  local name="$1" file public app ignored
  file="$(service_manifest_directory "$name")/ports"
  [[ -f "$file" ]] || return 1
  while read -r public app ignored; do
    [[ "$public" == '#'* ]] && continue
    service_port_valid "$public" && service_port_valid "$app" || continue
    printf '%s\t%s\n' "$public" "$app"
  done < "$file"
}

service_lease_read() {
  local name="$1" file owner expires
  file="$(service_directory "$name")/lease.tsv"
  [[ -f "$file" ]] || return 1
  IFS=$'\t' read -r owner expires < "$file" || return 1
  [[ -n "$owner" && "$expires" =~ ^[0-9]+$ ]] || return 1
  printf '%s\t%s' "$owner" "$expires"
}

service_claim() {
  local name="$1" worker="$2" directory routes lease owner expires now ttl lease_row routes_body
  service_validate_name "$name" && service_worker_valid "$worker" || return 1
  routes="$(service_ports "$name")" || return 2
  [[ -n "$routes" ]] || return 2
  directory="$(service_directory "$name")"
  service_lock "$directory" || return 1
  now="$(date +%s)"
  ttl="$(service_ttl)"
  if lease="$(service_lease_read "$name")"; then
    IFS=$'\t' read -r owner expires <<< "$lease"
    if (( expires > now )) && [[ "$owner" != "$worker" ]]; then
      service_unlock
      return 3
    fi
  fi
  lease_row="$(printf '%s\t%s\n' "$worker" "$((now + ttl))")"
  routes_body="$(printf '%s\n' "$routes")"
  if ! service_write_atomic "$directory/lease.tsv" "$lease_row" \
     || ! service_write_atomic "$directory/routes.tsv" "$routes_body"; then
    service_unlock
    return 1
  fi
  service_unlock
}

service_heartbeat() {
  local name="$1" worker="$2" directory lease owner expires now ttl lease_row
  service_validate_name "$name" && service_worker_valid "$worker" || return 1
  directory="$(service_directory "$name")"
  service_lock "$directory" || return 1
  if ! lease="$(service_lease_read "$name")"; then
    service_unlock
    return 3
  fi
  IFS=$'\t' read -r owner expires <<< "$lease"
  [[ "$owner" == "$worker" ]] || { service_unlock; return 3; }
  now="$(date +%s)"
  ttl="$(service_ttl)"
  lease_row="$(printf '%s\t%s\n' "$worker" "$((now + ttl))")"
  if ! service_write_atomic "$directory/lease.tsv" "$lease_row"; then
    service_unlock
    return 1
  fi
  service_unlock
}

service_release() {
  local name="$1" worker="$2" directory lease owner expires
  service_validate_name "$name" && service_worker_valid "$worker" || return 1
  directory="$(service_directory "$name")"
  service_lock "$directory" || return 1
  if lease="$(service_lease_read "$name")"; then
    IFS=$'\t' read -r owner expires <<< "$lease"
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

service_router_pid_ok() {
  local pid="$1" public="$2"
  [[ -r "/proc/$pid/cmdline" ]] || return 1
  tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q "TCP-LISTEN:$public,"
}

service_router_stop() {
  local root pidfile public pid
  root="$(service_root)"
  for pidfile in "$root"/router/*.pid; do
    [[ -f "$pidfile" ]] || continue
    public="${pidfile##*/}"; public="${public%.pid}"
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && service_router_pid_ok "$pid" "$public"; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f -- "$pidfile" "$root/router/$public.target"
  done
}

service_router_sync() {
  local root router lease directory owner expires public app target pidfile targetfile pid old_target
  local -A wanted=()
  root="$(service_root)"
  router="$root/router"
  mkdir -p -- "$router"

  for lease in "$root"/*/lease.tsv; do
    [[ -f "$lease" ]] || continue
    directory="${lease%/*}"
    IFS=$'\t' read -r owner expires < "$lease" || continue
    [[ "$expires" =~ ^[0-9]+$ ]] || continue
    (( expires > $(date +%s) )) || continue
    [[ -f "$directory/routes.tsv" ]] || continue
    while IFS=$'\t' read -r public app; do
      service_port_valid "$public" && service_port_valid "$app" || continue
      wanted["$public"]="$owner:$app"
    done < "$directory/routes.tsv"
  done

  if (( ${#wanted[@]} )); then
    for public in "${!wanted[@]}"; do
      target="${wanted[$public]}"
      pidfile="$router/$public.pid"
      targetfile="$router/$public.target"
      pid="$(cat "$pidfile" 2>/dev/null || true)"
      old_target="$(cat "$targetfile" 2>/dev/null || true)"
      if [[ "$pid" =~ ^[0-9]+$ ]] && service_router_pid_ok "$pid" "$public" \
         && [[ "$old_target" == "$target" ]]; then
        continue
      fi
      [[ "$pid" =~ ^[0-9]+$ ]] && service_router_pid_ok "$pid" "$public" && kill "$pid" 2>/dev/null || true
      printf '%s\n' "$target" > "$targetfile"
      socat "TCP-LISTEN:$public,fork,reuseaddr" "TCP:$target" >> "$router/router.log" 2>&1 &
      printf '%s\n' "$!" > "$pidfile"
    done
  fi

  for pidfile in "$router"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    public="${pidfile##*/}"; public="${public%.pid}"
    [[ -n "${wanted[$public]:-}" ]] && continue
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] && service_router_pid_ok "$pid" "$public" && kill "$pid" 2>/dev/null || true
    rm -f -- "$pidfile" "$router/$public.target"
  done
}
