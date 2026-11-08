#!/usr/bin/env bash
# network.sh — WireGuard + firewall command wrapper (logic lives in lib/wireguard.sh).
# Usage: network.sh {open|nat|all|setup|join <server_public_key>}
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/core.sh"
. "$SCRIPT_DIR/lib/wireguard.sh"
load_config

case "${1:-all}" in
  open)   open_ports ;;
  nat)    setup_nat ;;
  all)    open_ports; setup_nat ;;
  setup)  configure_wireguard_server ;;
  join)   shift; join_wireguard "$@" ;;
  *)
    printf 'usage: %s {open|nat|all|setup|join <server_public_key>}\n' "$0" >&2
    exit 2
    ;;
esac
