#!/usr/bin/env bash
# worker_server.sh - start a worker HTTP listener.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEAUT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$BEAUT_ROOT/lib/common.sh"
. "$BEAUT_ROOT/lib/config.sh"
. "$BEAUT_ROOT/lib/store.sh"
. "$BEAUT_ROOT/lib/routes.sh"
. "$BEAUT_ROOT/lib/workers.sh"
. "$BEAUT_ROOT/lib/docker.sh"

beaut_load_config
export BEAUT_CONFIG BEAUT_ROOT
export BEAUT_ROLE=worker
BEAUT_NODE_NAME="$BEAUT_WORKER_NAME"
export BEAUT_NODE_NAME
beaut_state_init
store_init
beaut_require socat

if docker_available; then
  beaut_log "restoring local sessions"
  docker_restore_all || beaut_warn "some local sessions could not be restored"
else
  beaut_warn "docker not available; session endpoints will fail"
fi

beaut_log "worker ${BEAUT_WORKER_NAME} listening on ${BEAUT_WORKER_BIND}:${BEAUT_WORKER_PORT}"
exec socat "TCP-LISTEN:${BEAUT_WORKER_PORT},bind=${BEAUT_WORKER_BIND},fork,reuseaddr" \
  "EXEC:${BEAUT_ROOT}/server/worker_handler.sh"
