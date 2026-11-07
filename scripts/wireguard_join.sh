#!/usr/bin/env bash
# wireguard_join.sh — join WireGuard on the NODE side (delegates to network.sh).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/core.sh"
load_config

state_init

[[ -n "${1:-}" ]] || { log error "usage: $0 <server_public_key>"; exit 2; }

bash "$SCRIPT_DIR/network.sh" join "$1"
