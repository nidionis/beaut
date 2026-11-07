#!/usr/bin/env bash
# http_exec.sh — script cote NODE (a executer via: curl $DOMAIN | sh).
# Reclame un travail, l'execute localement, rapporte le resultat.
set -uo pipefail

# DOMAIN peut etre surcharge par l'environnement ou le premier argument
DOMAIN="${1:-${DOMAIN:-127.0.0.1}}"
HTTP_PORT="${HTTP_PORT:-8080}"

BASE="http://$DOMAIN:$HTTP_PORT"

# 1. Reclamer un nouveau token
TOKEN="$(curl -s "$BASE/work")"
if [[ -z "$TOKEN" ]]; then
  echo "echec: aucun token recu" >&2
  exit 1
fi
echo "token recu: $TOKEN"

# 2. Recuperer la commande associee au token
CMD="$(curl -s "$BASE/work/$TOKEN")"
if [[ -z "$CMD" || "$CMD" == *"erreur"* || "$CMD" == *"expire"* ]]; then
  echo "echec: commande indisponible pour le token $TOKEN" >&2
  echo "$CMD" >&2
  exit 1
fi
echo "commande: $CMD"

# 3. Executer localement
OUT="$(bash -c "$CMD" 2>&1)"
EXIT=$?

# 4. Rendre le resultat
curl -s -X POST "$BASE/done/$TOKEN" --data-urlencode "output=$OUT" >/dev/null
echo "resultat envoye sur /done/$TOKEN (sortie: $EXIT)"

exit $EXIT
