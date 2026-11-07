#!/usr/bin/env bash
# actions/done.sh — endpoint /done/<TOKEN> (POST)
# Reçoit le résultat d'un agent pour un token donné.
#
# Le serveur vérifie le résultat (1 fois sur N=2, aléatoirement) en attendant
# le même calcul d'une autre connexion (autre token). Si les résultats
# correspondent, la tâche est validée.
set -uo pipefail

ADIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BDIR="$(cd "$ADIR/.." && pwd)"
. "$BDIR/lib/core.sh"
load_config "$@"
# Re-établir ADIR après core.sh
ADIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

state_init

# Extraire le TOKEN depuis l'URL : /done/<TOKEN>
# Le corps est sur stdin (passé par http_handler.sh)
body="$(cat)"

# Le token est dans le chemin, pas dans le corps
# http_handler.sh doit nous le transmettre via une variable d'environnement
TOKEN="${DONE_TOKEN:-}"

if [[ -z "$TOKEN" ]]; then
  echo "erreur: token manquant dans l'URL"
  exit 1
fi

# Parse du corps
get_param() {
  local key="$1"
  printf '%s' "$body" | awk -F'[&?]' -v k="$key" '{
    for (i=1;i<=NF;i++) {
      split($i,a,"=");
      if (a[1]==k) { print a[2]; exit }
    }
  }'
}

STATUS="$(get_param status)"
OUTPUT="$(get_param output)"
ELAPSED="$(get_param elapsed)"
TS="$(date +%s)"

# Vérifier que le token existe et n'est pas expiré
if ! tsv_find "$STATE_DIR/assignments.tsv" 1 "$TOKEN" | grep -q .; then
  echo "erreur: token inconnu $TOKEN"
  exit 1
fi

EXPIRY="$(tsv_find "$STATE_DIR/assignments.tsv" 1 "$TOKEN" | tsv_field 4 2>/dev/null)"
if [[ -n "$EXPIRY" && "$TS" -gt "$EXPIRY" ]]; then
  echo "erreur: token expiré"
  exit 1
fi

# Sauvegarder le résultat
mkdir -p "$STATE_DIR/results"
printf '%s' "$OUTPUT" | sed 's/%20/ /g' > "$STATE_DIR/results/$TOKEN"
tsv_update "$STATE_DIR/tasks.tsv" 4 "$STATUS" 1 "$TOKEN" 2>/dev/null || true

echo "réultat reçu: $TOKEN → $STATUS (élapsé: ${ELAPSED:-?}s)"

# --- Vérification aléatoire (1 sur N=2) --------------------------------------
VERIFY_FILE="$STATE_DIR/assignments/$TOKEN.verify"
if [[ -f "$VERIFY_FILE" ]]; then
  VERIFY_REQUIRED="$(cat "$VERIFY_FILE")"
else
  VERIFY_REQUIRED=0
fi

if [[ "$VERIFY_REQUIRED" -eq 1 ]]; then
  echo "Vérification croisée requise pour $TOKEN."
  # Marquer que ce token a fourni son résultat
  echo "$STATUS:$OUTPUT" > "$STATE_DIR/results/$TOKEN.verify"

  # Attendre un autre token avec le même TASK_ID pour comparaison
  TASK_ID="$(tsv_find "$STATE_DIR/assignments.tsv" 1 "$TOKEN" | tsv_field 3 2>/dev/null)"
  if [[ -n "$TASK_ID" ]]; then
    echo "En attente d'un second calcul pour $TASK_ID (timeout 30s)..."
    WAIT_END=$(( TS + 30 ))
    while [[ "$(date +%s)" -lt "$WAIT_END" ]]; do
      # Chercher un autre token avec le même TASK_ID qui a un résultat
      OTHER_TOKEN="$(awk -F'\t' -v tid="$TASK_ID" -v tok="$TOKEN" '$2==tid && $1!=tok {print $1; exit}' "$STATE_DIR/assignments.tsv" 2>/dev/null)"
      if [[ -n "$OTHER_TOKEN" ]] && [[ -f "$STATE_DIR/results/$OTHER_TOKEN.verify" ]]; then
        OTHER_RESULT="$(cat "$STATE_DIR/results/$OTHER_TOKEN.verify")"
        if [[ "$OTHER_RESULT" == "$STATUS:$OUTPUT" ]]; then
          echo "Vérification réussie : résultats identiques (token $OTHER_TOKEN)."
          echo "validé" > "$STATE_DIR/results/$TOKEN.verified"
        else
          echo "Vérification échouée : résultats différents (token $OTHER_TOKEN)."
          echo "invalide" > "$STATE_DIR/results/$TOKEN.verified"
        fi
        break
      fi
      sleep 2
    done
    if [[ ! -f "$STATE_DIR/results/$TOKEN.verified" ]]; then
      echo "Vérification incomplète : aucun second résultat reçu à temps."
    fi
  fi
fi
