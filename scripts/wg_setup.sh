#!/usr/bin/env bash
# wg_setup.sh — configure WireGuard cote SERVEUR (delègue a net.sh).
set -uo pipefail

SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BDIR="$(cd "$SDIR/.." && pwd)"
. "$BDIR/lib/core.sh"
load_config

state_init

bash "$SDIR/net.sh" setup
bash "$SDIR/net.sh" open
