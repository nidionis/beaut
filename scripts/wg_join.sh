#!/usr/bin/env bash
# wg_join.sh — rejoint le WireGuard cote NODE (delègue a net.sh).
set -uo pipefail

SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BDIR="$(cd "$SDIR/.." && pwd)"
. "$BDIR/lib/core.sh"
load_config

state_init

[[ -n "${1:-}" ]] || { log error "usage: wg_join.sh <serveur_pub_key>"; exit 2; }

bash "$SDIR/net.sh" join "$1"
