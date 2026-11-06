#!/usr/bin/env bash
# lib/core.sh — briques partagées (minimaliste)
# Chargement config, logging, état TSV + flock, appel du hub (SSH pur).
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/../.." && pwd)"

load_config() {
  local env_file="${1:-$ROOT_DIR/config.env}"
  [[ -f "$env_file" ]] || env_file="$ROOT_DIR/config.env.example"
  if [[ -f "$env_file" ]]; then
    set -a; . "$env_file"; set +a
  fi
  [[ -f "$ROOT_DIR/.env" ]] && { set -a; . "$ROOT_DIR/.env"; set +a; }

  NAME="${NAME:-beaut}"
  DIR="${DIR:-$HOME/.$NAME}"
  STATE_DIR="${STATE_DIR:-$DIR/state}"
  HUB_HOST="${HUB_HOST:-127.0.0.1}"
  HUB_PORT="${HUB_PORT:-2222}"
  HUB_USER="${HUB_USER:-$USER}"
  WORKER_STALE_SECONDS="${WORKER_STALE_SECONDS:-60}"
  HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-15}"
  LEASE_TTL_SECONDS="${LEASE_TTL_SECONDS:-300}"
  LOG_LEVEL="${LOG_LEVEL:-info}"
  CLIENT_KEYS="${CLIENT_KEYS:-$DIR/clients}"
  WORKER_KEYS="${WORKER_KEYS:-$DIR/workers}"

  export NAME DIR STATE_DIR HUB_HOST HUB_PORT HUB_USER \
    WORKER_STALE_SECONDS HEARTBEAT_INTERVAL LEASE_TTL_SECONDS LOG_LEVEL \
    CLIENT_KEYS WORKER_KEYS
}

log() {
  local level="$1"; shift
  case "$LOG_LEVEL" in
    debug) ;;
    info)  [[ "$level" == "debug" ]] && return ;;
    warn)  [[ "$level" == "debug" || "$level" == "info" ]] && return ;;
    error) [[ "$level" != "error" ]] && return ;;
  esac
  printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$level" "$*" >&2
}

state_init() {
  mkdir -p "$STATE_DIR/results" "$STATE_DIR/heartbeats" "$STATE_DIR/tasks"
  [[ -f "$STATE_DIR/workers.tsv"     ]] || : > "$STATE_DIR/workers.tsv"
  [[ -f "$STATE_DIR/tasks.tsv"       ]] || : > "$STATE_DIR/tasks.tsv"
  [[ -f "$STATE_DIR/assignments.tsv" ]] || : > "$STATE_DIR/assignments.tsv"
}

with_lock() {
  local lock_file="$1"; shift
  (
    flock 9
    "$@"
  ) 9>"$lock_file"
}

is_local_host() {
  [[ "$HUB_HOST" == "127.0.0.1" || "$HUB_HOST" == "localhost" ]]
}

sh_quote_arg() {
  local a="$1"
  a="${a//\'/\'\\\'\'}"
  printf "'%s'" "$a"
}

ssh_hub() {
  local subcmd="$1"; shift
  local quoted=""
  local a
  for a in "$@"; do
    quoted+=" $(sh_quote_arg "$a")"
  done
  if is_local_host; then
    bash "$ROOT_DIR/scripts/hub.sh" "$subcmd" "$@"
  else
    ssh -p "$HUB_PORT" "$HUB_USER@$HUB_HOST" \
      "bash -lc 'cd \"$ROOT_DIR\" && exec bash scripts/hub.sh $subcmd$quoted'"
  fi
}

uid() {
  printf '%s.%s' "$$" "$(date +%s%N)"
}
