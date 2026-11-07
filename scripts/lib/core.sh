#!/usr/bin/env bash
# lib/core.sh — shared pure-bash building blocks (sourced, no auto-execution).
# All configuration lives in config.env / config.env.example; sourcing them with
# `set -a` is what exports them, so there is no hand-maintained export list.
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$LIB_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
FILES_DIR="$PROJECT_ROOT/deploy/files"

. "$LIB_DIR/state.sh"

# Environment overrides config.env, which overrides config.env.example.
# The example is also the schema: it fills any variable a stale config.env omits.
load_config() {
  local config_file="${1:-$PROJECT_ROOT/config.env}"
  local example_file="$PROJECT_ROOT/config.env.example"
  set -a
  [[ -f "$config_file" ]] && . "$config_file"
  [[ -f "$example_file" && "$example_file" != "$config_file" ]] && . "$example_file"
  set +a
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

die() {
  log error "$*"
  exit 1
}

has_command() {
  command -v "$1" >/dev/null 2>&1
}

state_init() {
  mkdir -p "$STATE_DIR"
  [[ -f "$STATE_DIR/db.tsv" ]] || : > "$STATE_DIR/db.tsv"
}

new_id() {
  printf '%s.%s' "$$" "$(date +%s%N)"
}
