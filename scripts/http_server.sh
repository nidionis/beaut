#!/usr/bin/env bash
# http_server.sh — launch the HTTP manager through socat.
# One connection = one handler (http_handler.sh). The server never computes.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/core.sh"
load_config

has_command socat || die "socat is required for the HTTP server"

state_init

log info "HTTP server on $SERVER_HOST:$HTTP_PORT (script/token server, no execution)"

socat TCP-LISTEN:"$HTTP_PORT",fork EXEC:"bash $SCRIPT_DIR/http_handler.sh"
