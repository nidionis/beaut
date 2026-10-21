#!/usr/bin/env bash
# scripts/lib.sh — shared helpers. Sourced, never executed.
# shellcheck shell=bash
#
# Single source of truth for: logging, config loading, path layout, template
# rendering, and small conf-file edits. install.sh / build.sh / deploy.sh all
# use it, so there is exactly one definition of each.

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
info() { printf '     %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# BIN_DIR is a common name in build environments; never inherit a foreign one.
unset BIN_DIR

# load_config [file] — source and validate a config.env
load_config() {
  local f="${1:-$ROOT/config.env}"
  [ -f "$f" ] || die "config not found: $f (copy config.env.example to config.env and edit)"
  set -a
  # shellcheck disable=SC1090
  . "$f"
  set +a
  : "${BEAUT_PASSWORD:?config.env must define BEAUT_PASSWORD}"
  : "${ROLE:?config.env must define ROLE (orchestrator|router|worker|client)}"
  case "$ROLE" in
    orchestrator|router|worker|client) ;;
    *) die "unknown ROLE: $ROLE (orchestrator|router|worker|client)" ;;
  esac
  log "config loaded from ${f#"$ROOT"/} (role=$ROLE)"
}

# source_config — read config.env without validating (status/uninstall paths)
source_config() {
  [ -f "$ROOT/config.env" ] || return 0
  set -a
  # shellcheck disable=SC1090
  . "$ROOT/config.env"
  set +a
}

# resolve_paths — derive the whole layout from NAME / PREFIX.
# Everything is user-writable; nothing here needs root.
resolve_paths() {
  NAME="${NAME:-beaut}"
  PREFIX="${PREFIX:-$HOME/.$NAME}"
  BIN_DIR="${BIN_DIR:-${BEAUT_BIN_DIR:-$HOME/.bin}}"   # may live outside PREFIX
  LIB_DIR="$PREFIX/lib/$NAME"
  ENV_DIR="${ENV_DIR:-$PREFIX/etc}"
  STATE_DIR="${STATE_DIR:-$PREFIX/var}"
  CONF="$ENV_DIR/$NAME.conf"
  SECRET="$ENV_DIR/$NAME.env"
  TOOL="$LIB_DIR/$NAME-bin"          # internal C binary — not in PATH
}

# conf_set <file> <key> <value> — set or append KEY=VALUE
conf_set() {
  local f="$1" k="$2" v="$3" tmp
  tmp="$(mktemp)"
  awk -v k="$k" -v v="$v" '
    $0 ~ "^" k "=" { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$f" > "$tmp"
  cat "$tmp" > "$f"
  rm -f "$tmp"
}

# conf_add <file> <key> <value> — append value to a space-separated list
conf_add() {
  local f="$1" k="$2" v="$3" cur
  cur="$(sed -n "s/^$k=//p" "$f" | tail -1 | tr -d '"')"
  conf_set "$f" "$k" "\"$(printf '%s %s' "$cur" "$v" | xargs)\""
}

# render <template> <output> — @VAR@ substitution from the resolved layout
render() {
  local t="$1" o="$2"
  sed \
    -e "s|@NAME@|$NAME|g" \
    -e "s|@PREFIX@|$PREFIX|g" \
    -e "s|@BIN_DIR@|$BIN_DIR|g" \
    -e "s|@LIB_DIR@|$LIB_DIR|g" \
    -e "s|@ENV_DIR@|$ENV_DIR|g" \
    -e "s|@STATE_DIR@|$STATE_DIR|g" \
    -e "s|@CONF@|$CONF|g" \
    -e "s|@SECRET@|$SECRET|g" \
    -e "s|@TOOL@|$TOOL|g" \
    -e "s|@ROLE@|${ROLE:-}|g" \
    -e "s|@BEAUT_IF@|${BEAUT_IF:-lo}|g" \
    -e "s|@BEAUT_HEARTBEAT_S@|${BEAUT_HEARTBEAT_S:-30}|g" \
    "$t" > "$o"
}

# local_ip — first non-loopback IPv4 address
local_ip() {
  ip -4 addr show 2>/dev/null \
    | awk '/inet /{print $2}' | cut -d/ -f1 \
    | grep -v '^127\.' | head -1 || true
}
