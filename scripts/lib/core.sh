#!/usr/bin/env bash
# lib/core.sh — briques partagées pur bash (sourcé, pas d'auto-exécution)
# Style pure-bash-bible : parameter expansion, builtins, pas de jq/python.
set -uo pipefail

# LIB_DIR est le répertoire de ce fichier (scripts/lib)
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SCRIPTS_DIR est le répertoire parent (scripts), sauf si déjà défini
SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$LIB_DIR/.." && pwd)}"
ROOT_DIR="${ROOT_DIR:-$(cd "$SCRIPTS_DIR/.." && pwd)}"

# Source les libs TSV factorisées (relatives à LIB_DIR)
. "$LIB_DIR/tsv/find.sh"
. "$LIB_DIR/tsv/field.sh"
. "$LIB_DIR/tsv/append.sh"
. "$LIB_DIR/tsv/update.sh"
. "$LIB_DIR/tsv/stale.sh"
. "$LIB_DIR/tsv/filter.sh"

# Source la lib de liste de confiance
. "$LIB_DIR/trusted.sh"

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
  LEASE_TTL_SECONDS="${LEASE_TTL_SECONDS:-300}"
  HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-15}"
  WORKER_STALE_SECONDS="${WORKER_STALE_SECONDS:-60}"
  LOG_LEVEL="${LOG_LEVEL:-info}"
  NICE_ROOT="${NICE_ROOT:--20}"
  NICE_VIP="${NICE_VIP:-0}"
  NICE_GUEST="${NICE_GUEST:-19}"

  export NAME DIR STATE_DIR DOMAIN HTTP_PORT WG_PORT WG_NET WG_SERVER_IP \
    LEASE_TTL_SECONDS HEARTBEAT_INTERVAL WORKER_STALE_SECONDS LOG_LEVEL \
    NICE_ROOT NICE_VIP NICE_GUEST
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
  mkdir -p "$STATE_DIR/results" "$STATE_DIR/actions"
  [[ -f "$STATE_DIR/workers.tsv"     ]] || : > "$STATE_DIR/workers.tsv"
  [[ -f "$STATE_DIR/tasks.tsv"       ]] || : > "$STATE_DIR/tasks.tsv"
  [[ -f "$STATE_DIR/assignments.tsv" ]] || : > "$STATE_DIR/assignments.tsv"
  [[ -f "$STATE_DIR/workers.trusted" ]] || : > "$STATE_DIR/workers.trusted"
}

with_lock() {
  local lock_file="$1"; shift
  (
    flock 9
    "$@"
  ) 9>"$lock_file"
}

uid() {
  printf '%s.%s' "$$" "$(date +%s%N)"
}

# Résout la priorité nice d'un worker à partir de workers.tsv
# Colonne 3 = role, colonne 6 = statut (alive/stale)
worker_nice() {
  local wid="$1"
  local line role
  line="$(tsv_find "$STATE_DIR/workers.tsv" 1 "$wid")"
  [[ -z "$line" ]] && { echo "${NICE_GUEST:+19}"; return; }
  role="$(tsv_field "$line" 3)"
  case "$role" in
    root|admin) echo "${NICE_ROOT:- -20}" ;;
    vip)        echo "${NICE_VIP:-0}" ;;
    *)          echo "${NICE_GUEST:+19}" ;;
  esac
}

# HTTP response helper (minimaliste, texte brut)
http_response() {
  local code="${1:-200}"; shift
  local body="$*"
  local len; len="${#body}"
  printf 'HTTP/1.1 %s OK\r\nContent-Length: %s\r\nContent-Type: text/plain\r\n\r\n%s' "$code" "$len" "$body"
}

# HTTP response helper (page HTML enveloppant la sortie d'un script)
http_html_response() {
  local code="${1:-200}"; shift
  local body="$*"
  local len
  len="$(printf '%s' "$body" | wc -c)"
  printf 'HTTP/1.1 %s OK\r\nContent-Length: %s\r\nContent-Type: text/html\r\n\r\n' "$code" "$len"
  printf '<html><head><meta charset="utf-8"><title>beaut</title></head><body><pre>%s</pre></body></html>' "$body"
}

# Vérifie qu'une commande existe
cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}
