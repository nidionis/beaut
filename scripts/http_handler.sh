#!/usr/bin/env bash
# http_handler.sh — gère une connexion HTTP individuelle.
# stdin = requête reçue, stdout = réponse envoyée.
# Appelé par socat via EXEC depuis http_server.sh.
#
# Routage :
#   - /done/<TOKEN>   → scripts/actions/done.sh (DONE_TOKEN exporté)
#   - /<mot-clef>/<n> → scripts/cmds/<mot-clef>/<n>, puis <mot-clef>/DEFAUT.sh, puis DEFAUT.sh
#   - /<action>       → scripts/actions/<action>.sh (classique)
set -uo pipefail

SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SDIR/lib/core.sh"

# Lit les en-têtes HTTP ligne par ligne jusqu'à la ligne vide
headers=""
while IFS= read -r -t 5 line; do
    line="${line%$'\r'}"
    headers+="$line"$'\n'
    [[ -z "$line" ]] && break
done

# Première ligne = requête HTTP (ex: POST /give/50 HTTP/1.1)
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

# Détermine le script à exécuter
SCRIPT=""

if [[ "$action" == done/* ]]; then
  # /done/<TOKEN>
  TOKEN="${action#done/}"
  export DONE_TOKEN="$TOKEN"
  SCRIPT="$SDIR/../actions/done.sh"
elif [[ "$action" == */* ]]; then
  # /<mot-clef>/<numero>
  MOT_CLEF="${action%%/*}"
  NUMERO="${action#*/}"
  # Cherche scripts/cmds/<mot-clef>/<numero>
  if [[ -f "$SDIR/../cmds/$MOT_CLEF/$NUMERO" ]]; then
    SCRIPT="$SDIR/../cmds/$MOT_CLEF/$NUMERO"
  elif [[ -f "$SDIR/../cmds/$MOT_CLEF/DEFAUT.sh" ]]; then
    SCRIPT="$SDIR/../cmds/$MOT_CLEF/DEFAUT.sh"
  elif [[ -f "$SDIR/../cmds/DEFAUT.sh" ]]; then
    SCRIPT="$SDIR/../cmds/DEFAUT.sh"
  fi
elif [[ -n "$action" && -f "$SDIR/../actions/$action.sh" ]]; then
  SCRIPT="$SDIR/../actions/$action.sh"
elif [[ -f "$SDIR/../cmds/DEFAUT.sh" ]]; then
  SCRIPT="$SDIR/../cmds/DEFAUT.sh"
fi

# Exécute le script cible, en passant le corps sur stdin
if [[ -n "$SCRIPT" && -f "$SCRIPT" ]]; then
    resp="$(printf '%s\n' "$req_body" | bash "$SCRIPT" 2>&1)"
else
    resp="erreur: action inconnue '${action:-(vide)}'"
fi

http_response 200 "$resp"
