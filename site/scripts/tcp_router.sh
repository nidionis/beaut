#!/usr/bin/env bash
# tcp_router.sh — forward public TCP ports to the worker holding each lease.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/core.sh"
. "$SCRIPT_DIR/lib/services.sh"
load_config

has_command socat || die "socat is required for TCP routing"

trap 'service_router_stop' EXIT
trap 'exit 0' INT TERM
log info "tcp router: $(service_root)"
while :; do
  service_router_sync
  sleep "${SERVICE_ROUTER_INTERVAL:-1}"
done
