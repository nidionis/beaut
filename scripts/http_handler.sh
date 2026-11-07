#!/usr/bin/env bash
# http_handler.sh — gère une connexion HTTP individuelle.
# stdin = requête reçue, stdout = réponse envoyée.
# Appelé par socat via EXEC depuis http_server.sh.
# Dispatch vers scripts/actions/<action>.sh selon le chemin de l'URL.
set -uo pipefail

# Répertoire de ce script (scripts/)
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source core.sh (définit les helpers TSV, trusted, etc.)
. "$SDIR/lib/core.sh"

# Lit les en-têtes HTTP ligne par ligne jusqu'à la ligne vide
headers=""
while IFS= read -r -t 5 line; do
    line="${line%$'\r'}"
    headers+="$line"$'\n'
    [[ -z "$line" ]] && break
done

# Première ligne = requête HTTP (ex: POST /give HTTP/1.1)
first_line="$(printf '%s\n' "$headers" | head -n1)"
path="$(printf '%s\n' "$first_line" | awk '{print $2}')"
action="${path#/}"
action="${action%% *}"
action="${action%%\?*}"

# Content-Length pour le corps POST
content_length="$(printf '%s\n' "$headers" | awk -F': ' 'tolower($1)=="content-length"{gsub(/\r/,"",$2); print $2}')"

# Lit le corps POST exactement Content-Length octets
req_body=""
if [[ -n "$content_length" && "$content_length" -gt 0 ]] 2>/dev/null; then
    req_body="$(dd bs=1 count="$content_length" 2>/dev/null)"
fi

# Exécute l'action correspondante, en passant le corps en stdin
action_script="$SDIR/actions/$action.sh"
if [[ -n "$action" && -f "$action_script" ]]; then
    resp="$(printf '%s\n' "$req_body" | bash "$action_script" 2>&1)"
else
    resp="erreur: action inconnue '${action:-(vide)}'"
fi

http_response 200 "$resp"
