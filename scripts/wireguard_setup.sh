#!/usr/bin/env bash
# wireguard_setup.sh — configure WireGuard on the SERVER side (delegates to network.sh).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/core.sh"
load_config

state_init

bash "$SCRIPT_DIR/network.sh" setup
bash "$SCRIPT_DIR/network.sh" open
