#!/usr/bin/env bash
# lib/core.sh — briques partagées pur bash (sourcé, pas d'auto-exécution)
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$LIB_DIR/.." && pwd)}"
ROOT_DIR="${ROOT_DIR:-$(cd "$SCRIPTS_DIR/.." && pwd)}"

# Source la librairie d'état (TSV unique)
. "$LIB_DIR/state.sh"

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
  DOMAIN="${DOMAIN:-192.168.8.240}"
  HTTP_PORT="${HTTP_PORT:-8080}"
  WG_PORT="${WG_PORT:-51820}"
  WG_NET="${WG_NET:-10.66.0.0/24}"
  WG_SERVER_IP="${WG_SERVER_IP:-10.66.0.1}"
  TOKEN_TTL_SECONDS="${TOKEN_TTL_SECONDS:-300}"
  LOG_LEVEL="${LOG_LEVEL:-info}"
  HTTP_FILE_ROOT="${HTTP_FILE_ROOT:-$DIR/shared}"
  ERR404="${ERR404:-404}"
  HIST_MEM_MAX_RATIO="${HIST_MEM_MAX_RATIO:-5}"

  export NAME DIR STATE_DIR DOMAIN HTTP_PORT WG_PORT WG_NET WG_SERVER_IP \
    TOKEN_TTL_SECONDS LOG_LEVEL HTTP_FILE_ROOT ERR404 HIST_MEM_MAX_RATIO
}

log() {
  local level="$1"; shift
  case "${LOG_LEVEL:-info}" in
    debug) ;;
    info)  [[ "$level" == "debug" ]] && return ;;
    warn)  [[ "$level" == "debug" || "$level" == "info" ]] && return ;;
    error) [[ "$level" != "error" ]] && return ;;
  esac
  printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$level" "$*" >&2
}

state_init() {
  mkdir -p "$STATE_DIR"
  [[ -f "$STATE_DIR/db.tsv" ]] || : > "$STATE_DIR/db.tsv"
}

uid() {
  printf '%s.%s' "$$" "$(date +%s%N)"
}

# Vérifie qu'une commande existe
cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}
