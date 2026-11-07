#!/usr/bin/env bash
# http.sh — serveur HTTP générique (socat) qui exécute un script cible
# et enveloppe sa sortie stdout dans une page HTML.
#
# Usage : ./http.sh --script <chemin_script> [--port <port>] [--host <host>]
#
# Le script cible reçoit la requête HTTP brute sur stdin et doit écrire
# sa réponse sur stdout. http.sh l'enveloppe automatiquement dans <html><pre>.
set -uo pipefail

SCRIPT=""
HOST="127.0.0.1"
PORT="8080"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --script) SCRIPT="$2"; shift 2 ;;
    --port)   PORT="$2"; shift 2 ;;
    --host)   HOST="$2"; shift 2 ;;
    *)        echo "option inconnue : $1" >&2; exit 2 ;;
  esac
done

[[ -n "$SCRIPT" ]] || { echo "usage: $0 --script <chemin> [--port <n>]" >&2; exit 2; }
[[ -f "$SCRIPT" ]] || { echo "script introuvable : $SCRIPT" >&2; exit 2; }

SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SDIR/lib/core.sh"

cmd_exists socat || { log error "socat requis pour le serveur HTTP"; exit 2; }

state_init

log info "serveur HTTP démarré sur $HOST:$PORT (script : $SCRIPT)"

# Pour chaque connexion, socat exécute http_handler.sh dont stdin/stdout
# sont connectés à la socket. Le handler lit la requête, lance le script
# cible, et enveloppe la sortie en HTML.
socat TCP-LISTEN:"$PORT",fork EXEC:"bash $SDIR/http_handler.sh --script $SCRIPT" 2>/dev/null
