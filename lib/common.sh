#!/usr/bin/env bash
# common.sh - shared paths, logging, state locking and small helpers.
# Sourced by the CLI and by both HTTP handlers.

set -uo pipefail

if [[ -z "${BEAUT_ROOT:-}" ]]; then
  BEAUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# Protected defaults live outside the operator-edited config.  Load them once,
# before any logging or protocol code, so every layer sees the same constants.
if [[ -z "${BEAUT_DEFAULTS_LOADED:-}" ]]; then
  BEAUT_DEFAULTS="${BEAUT_DEFAULTS:-${BEAUT_ROOT}/etc/beaut.defaults.conf}"
  if [[ -f "$BEAUT_DEFAULTS" ]]; then
    # shellcheck disable=SC1090
    . "$BEAUT_DEFAULTS"
    BEAUT_DEFAULTS_LOADED=1
  fi
fi

beaut_log() {
  printf '[%s] %s\n' "${BEAUT_NAME:-beaut}" "$*" >&2
}

beaut_warn() {
  printf '[%s] warning: %s\n' "${BEAUT_NAME:-beaut}" "$*" >&2
}

beaut_die() {
  printf '[%s] error: %s\n' "${BEAUT_NAME:-beaut}" "$*" >&2
  exit 1
}

beaut_has() {
  command -v "$1" >/dev/null 2>&1
}

beaut_require() {
  local command
  for command in "$@"; do
    beaut_has "$command" || beaut_die "required command not found: $command"
  done
}

beaut_now() {
  date +%s
}

beaut_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

beaut_rand_hex() {
  local bytes="${1:-16}"
  od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n'
}

beaut_sanitize_name() {
  local name="${1:-}"
  name="${name// /-}"
  name="${name//[^A-Za-z0-9._-]/}"
  name="${name:0:63}"
  [[ "$name" =~ ^[A-Za-z0-9] ]] || name="n${name}"
  printf '%s' "$name"
}

beaut_sanitize_var() {
  local name="${1:-}"
  name="${name//[^A-Za-z0-9_]/_}"
  printf '%s' "$name"
}

beaut_shell_quote() {
  printf '%q' "${1:-}"
}

beaut_url_encode() {
  local raw="${1:-}" out="" char i
  for ((i = 0; i < ${#raw}; i++)); do
    char="${raw:i:1}"
    case "$char" in
      [a-zA-Z0-9.~_-]) out+="$char" ;;
      *) printf -v char '%%%02X' "'$char"; out+="$char" ;;
    esac
  done
  printf '%s' "$out"
}

beaut_http_join() {
  local base="${1%/}" path="${2:-/}"
  [[ "$path" == /* ]] || path="/$path"
  printf '%s%s' "$base" "$path"
}

beaut_state_init() {
  mkdir -p -- \
    "$BEAUT_STATE_DIR" \
    "$BEAUT_STATE_DIR/sessions" \
    "$BEAUT_STATE_DIR/run" \
    "$BEAUT_STORE_DIR" \
    "$BEAUT_LOG_DIR"
  touch -- "$BEAUT_STATE_DIR/routes.tsv" "$BEAUT_STATE_DIR/workers.tsv"
  chmod 700 "$BEAUT_STATE_DIR" 2>/dev/null || true
}

beaut_lock_fd=""
beaut_lock_path=""

beaut_state_lock() {
  local timeout="${1:-5}"
  if ! beaut_has flock; then
    return 0
  fi
  beaut_lock_path="${BEAUT_STATE_DIR}/.lock"
  mkdir -p -- "$BEAUT_STATE_DIR"
  exec {beaut_lock_fd}>"$beaut_lock_path" || return 1
  flock -w "$timeout" "$beaut_lock_fd" || {
    exec {beaut_lock_fd}>&-
    beaut_lock_fd=""
    return 1
  }
}

beaut_state_unlock() {
  [[ -n "${beaut_lock_fd:-}" ]] || return 0
  exec {beaut_lock_fd}>&-
  beaut_lock_fd=""
  beaut_lock_path=""
}

beaut_atomic_write() {
  local path="$1" content="$2" tmp
  mkdir -p -- "$(dirname "$path")"
  tmp="${path}.tmp.$$"
  printf '%s\n' "$content" > "$tmp" || {
    rm -f -- "$tmp"
    return 1
  }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$path"
}

beaut_file_size() {
  local path="$1"
  if stat -c '%s' "$path" >/dev/null 2>&1; then
    stat -c '%s' "$path"
  else
    wc -c < "$path" | tr -d ' '
  fi
}

beaut_body_size() {
  [[ -n "${HTTP_BODY_FILE:-}" && -f "${HTTP_BODY_FILE:-}" ]] || {
    printf '0'
    return 0
  }
  beaut_file_size "$HTTP_BODY_FILE"
}

beaut_cleanup_files() {
  local file
  for file in "${@:-}"; do
    [[ -n "$file" && -e "$file" ]] && rm -rf -- "$file"
  done
}

beaut_pid_alive() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

beaut_write_pid() {
  local file="$1" pid="$2"
  mkdir -p -- "$(dirname "$file")"
  printf '%s\n' "$pid" > "$file"
}

beaut_read_pid() {
  local file="$1"
  [[ -f "$file" ]] && cat "$file" 2>/dev/null || true
}

beaut_stop_pidfile() {
  local file="$1" pid
  pid="$(beaut_read_pid "$file")"
  if beaut_pid_alive "$pid"; then
    kill "$pid" 2>/dev/null || true
    sleep 0.2
    beaut_pid_alive "$pid" && kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f -- "$file"
}

beaut_http_get() {
  local url="$1"
  curl -fsS --connect-timeout 2 --max-time "${2:-5}" "$url" 2>/dev/null
}

beaut_json_ok() {
  local body="${1:-}"
  jq -e . >/dev/null 2>&1 <<<"$body"
}
