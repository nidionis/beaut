#!/usr/bin/env bash
# hub_server.sh - start the hub HTTP listener (socat, one handler per connection).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEAUT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$BEAUT_ROOT/lib/common.sh"
. "$BEAUT_ROOT/lib/config.sh"
. "$BEAUT_ROOT/lib/store.sh"
. "$BEAUT_ROOT/lib/routes.sh"

beaut_load_config
export BEAUT_CONFIG BEAUT_ROOT
export BEAUT_ROLE=hub
beaut_state_init
store_init
routes_seed >/dev/null 2>&1 || true
beaut_require socat

beaut_log "hub ${BEAUT_HUB_NAME} listening on ${BEAUT_HUB_BIND}:${BEAUT_HUB_PORT}"
exec socat "TCP-LISTEN:${BEAUT_HUB_PORT},bind=${BEAUT_HUB_BIND},fork,reuseaddr" \
  "EXEC:${BEAUT_ROOT}/server/hub_handler.sh"
