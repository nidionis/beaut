#!/usr/bin/env bash
# http_server.sh — lance le gestionnaire HTTP via socat.
# Une connexion = un handler (http_handler.sh). Le serveur ne calcule jamais.
set -uo pipefail

SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SDIR/lib/core.sh"
load_config

cmd_exists socat || { log error "socat requis pour le serveur HTTP"; exit 2; }

state_init

log info "serveur HTTP sur $DOMAIN:$HTTP_PORT (serveur de scripts/tokens, pas d'execution)"

socat TCP-LISTEN:"$HTTP_PORT",fork EXEC:"bash $SDIR/http_handler.sh" 2>/dev/null
