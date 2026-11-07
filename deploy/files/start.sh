#!/usr/bin/env bash
# start.sh — launch the beaut HTTP server (standalone file, never inline).
# Configuration is loaded by http_server.sh through lib/core.sh load_config.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec bash "$SCRIPT_DIR/../../scripts/http_server.sh"
