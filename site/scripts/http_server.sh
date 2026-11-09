#!/usr/bin/env bash
# http_server.sh — launch the HTTP manager through a TCP listener.
# One connection = one handler (http_handler.sh). The server never computes.
# Listener order: socat (preferred), then a small C relay compiled from
# scripts/http_server.c (socat-enough fallback, no extra runtime packages).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/core.sh"
load_config

start_with_socat() {
  has_command socat || return 1
  exec socat TCP-LISTEN:"$HTTP_PORT",fork EXEC:"bash $SCRIPT_DIR/http_handler.sh"
}

start_with_c() {
  has_command gcc || return 1
  local binary="${HOME}/.cache/beaut/http-server"
  mkdir -p -- "${HOME}/.cache/beaut"
  if [[ ! -x "$binary" || "$SCRIPT_DIR/http_server.c" -nt "$binary" ]]; then
    gcc -o "$binary" "$SCRIPT_DIR/http_server.c" || { rm -f -- "$binary"; return 1; }
  fi
  exec "$binary" "$HTTP_PORT" "$SCRIPT_DIR/http_handler.sh"
}

start_with_socat || start_with_c || die "no TCP listener ready: install socat or gcc (scripts/http_server.c)"
