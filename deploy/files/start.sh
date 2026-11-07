#!/usr/bin/env bash
# start.sh — lance le serveur HTTP beaut (mode local --no-root).
# Fichier a part, copie par deploy.sh (jamais inline).
set -uo pipefail
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SDIR/../../config.env" ]] && { set -a; . "$SDIR/../../config.env"; set +a; }
export DOMAIN HTTP_PORT WG_PORT WG_NET WG_SERVER_IP \
  TOKEN_TTL_SECONDS LOG_LEVEL HTTP_FILE_ROOT ERR404 HIST_MEM_MAX_RATIO STATE_DIR
exec bash "$SDIR/../../scripts/http_server.sh"
