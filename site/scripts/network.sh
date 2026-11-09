#!/usr/bin/env bash
# network.sh — WireGuard + firewall command wrapper (logic lives in lib/wireguard.sh).
# Usage:
#   network.sh {open|nat|all|setup|sync-peers}
#   network.sh join <server_public_key>
#   network.sh client <server_public_key> <client_address>
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/core.sh"
. "$SCRIPT_DIR/lib/wireguard.sh"
load_config

case "${1:-all}" in
  open)       open_ports ;;
  nat)        setup_nat ;;
  all)        open_ports; setup_nat ;;
  setup)      configure_wireguard_server ;;
  sync-peers) sync_wireguard_peers ;;
  join)       shift; join_wireguard "$@" ;;
  client)     shift; configure_wireguard_client "$@" ;;
  *)
    printf 'usage: %s {open|nat|all|setup|sync-peers|join <server_public_key>|client <server_public_key> <client_address>}\n' "$0" >&2
    exit 2
    ;;
esac
