#!/usr/bin/env bash
# http_server.sh — mini serveur HTTP avec socat (bidirectionnel, fiable).
# Dispatch vers scripts/actions/<action>.sh selon le chemin de l'URL.
set -uo pipefail

SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SDIR/lib/core.sh"

cmd_exists socat || { log error "socat requis pour le serveur HTTP"; exit 2; }

state_init

log info "serveur HTTP démarré sur $DOMAIN:$HTTP_PORT"

# Pour chaque connexion, socat exécute http_handler.sh dont stdin/stdout
# sont connectés à la socket. Le handler lit la requête, dispatch, répond.
socat TCP-LISTEN:"$HTTP_PORT",fork EXEC:"bash $SDIR/http_handler.sh" 2>/dev/null
