#!/usr/bin/env bash
# beaut.sh — user entry point.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$ROOT_DIR/scripts/lib/core.sh"
load_config

case "${1:-}" in
  server)
    bash "$ROOT_DIR/scripts/network.sh" setup
    exec bash "$ROOT_DIR/scripts/http_server.sh"
    ;;
  node)
    shift
    exec bash "$ROOT_DIR/scripts/node.sh" "${1:-$SERVER_HOST}"
    ;;
  init)
    state_init
    echo "state initialized in $STATE_DIR"
    ;;
  device)
    shift
    exec bash "$ROOT_DIR/scripts/device.sh" "$@"
    ;;
  svr)
    shift
    exec bash "$ROOT_DIR/scripts/svr.sh" "$@"
    ;;
  *)
    cat >&2 <<EOF
usage: $0 {server|node|device|svr|init}
  server  configure WireGuard (requires root) and serve HTTP
  node    claim, execute and report one task
  device  per-device identity, invites and enrollment
  svr     hidden personal tree and Markdown journal
  init    create the state directory
EOF
    exit 2
    ;;
esac
