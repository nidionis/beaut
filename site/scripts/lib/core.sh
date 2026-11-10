#!/usr/bin/env bash
# lib/core.sh — shared paths, configuration, logging and git primitives.
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS_DIR="$(cd "$LIB_DIR/.." && pwd -P)"
SITE_DIRECTORY="$(cd "$SCRIPTS_DIR/.." && pwd -P)"
PROJECT_ROOT="$(cd "$SITE_DIRECTORY/.." && pwd -P)"
FILES_DIR="$SITE_DIRECTORY/deploy"

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

# Print the SHA-256 digest of a string as lowercase hex.
sha256_hex() {
  local value="${1:-}"
  if has_command sha256sum; then
    printf '%s' "$value" | sha256sum | awk '{print $1}'
  elif has_command shasum; then
    printf '%s' "$value" | shasum -a 256 | awk '{print $1}'
  elif has_command openssl; then
    printf '%s' "$value" | openssl dgst -sha256 | awk '{print $NF}'
  else
    printf 'no SHA-256 tool available (sha256sum, shasum or openssl)\n' >&2
    return 1
  fi
}

state_init() {
  mkdir -p -- "$STATE_DIR"
  : >> "$STATE_DIR/db.tsv"
}

# --- git --------------------------------------------------------------------
# One implementation for the personal tree and the journal.
git_run() {
  local root="$1"; shift
  git -C "$root" \
    -c user.name="${JOURNAL_GIT_NAME:-beaut}" \
    -c user.email="${JOURNAL_GIT_EMAIL:-beaut@localhost}" "$@"
}

git_repo() {
  [[ -e "$1/.git" ]] && return 0
  git -C "$1" rev-parse --git-dir >/dev/null 2>&1
}

git_init() {
  mkdir -p -- "$1" || return 1
  git_repo "$1" && return 0
  git -C "$1" init -q -b main 2>/dev/null || git -C "$1" init -q
}

# Accept pushes into a checked-out working tree (server-side repositories).
git_accept_pushes() {
  git_repo "$1" || return 0
  git -C "$1" config receive.denyCurrentBranch updateInstead >/dev/null 2>&1 || true
}

git_pull() {
  git_repo "$1" || return 0
  git_run "$1" pull --rebase --autostash >/dev/null 2>&1 || true
}

git_commit_all() {
  git_repo "$1" || return 0
  git_run "$1" add -A >/dev/null 2>&1 || true
  git_run "$1" commit -m "$2" >/dev/null 2>&1 || true
}

git_push() {
  git_repo "$1" || return 0
  git_run "$1" push --set-upstream origin HEAD >/dev/null 2>&1 || true
}
