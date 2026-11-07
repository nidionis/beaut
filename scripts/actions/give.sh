#!/usr/bin/env bash
# actions/give.sh — endpoint /give (POST)
# Le corps de la requête est transmis sur stdin par http_handler.sh.
#
# Deux modes :
# 1. action=register|heartbeat|result : gestion classique (enregistrement,
#    heartbeat, rapport de résultat).
# 2. Pas d'action : le serveur génère un token, associe une tâche, et
#    retourne un script shell à pipér dans | sh. Ce script, une fois exécuté
#    par l'agent, contacte le serveur pour obtenir la commande, l'exécute,
#    puis POSTe le résultat sur /done/<TOKEN> avant LEASE_TTL.
set -uo pipefail

ADIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BDIR="$(cd "$ADIR/.." && pwd)"
. "$BDIR/lib/core.sh"
load_config "$@"
# Re-établir ADIR après core.sh
ADIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

state_init

# Le corps POST est transmis sur stdin par http_handler.sh
body="$(cat)"

# Parse simple des paires key=val&key=val
get_param() {
  local key="$1"
  printf '%s' "$body" | awk -F'[&?]' -v k="$key" '{
    for (i=1;i<=NF;i++) {
      split($i,a,"=");
      if (a[1]==k) { print a[2]; exit }
    }
  }'
}

action="$(get_param action)"
wid="$(get_param id)"
pubkey="$(get_param pubkey)"
wg_ip="$(get_param wg_ip)"
role="$(get_param role)"
tid="$(get_param task_id)"
status="$(get_param task_status)"
output="$(get_param output)"

ts="$(date +%s)"

# --- Mode classique : register / heartbeat / result -------------------------
case "$action" in
  register)
    [[ -n "$wid" ]] || { echo "erreur: id manquant"; exit 1; }
    [[ -n "$role" ]] || role="guest"
    if tsv_find "$STATE_DIR/workers.tsv" 1 "$wid" | grep -q .; then
      tsv_update "$STATE_DIR/workers.tsv" 2 "$pubkey" 1 "$wid"
      tsv_update "$STATE_DIR/workers.tsv" 3 "$role" 1 "$wid"
      tsv_update "$STATE_DIR/workers.tsv" 4 "$wg_ip" 1 "$wid"
      tsv_update "$STATE_DIR/workers.tsv" 5 "$ts" 1 "$wid"
      tsv_update "$STATE_DIR/workers.tsv" 6 "alive" 1 "$wid"
    else
      tsv_append "$STATE_DIR/workers.tsv" "$wid" "$pubkey" "$role" "$wg_ip" "$ts" "alive"
    fi
    echo "enregistré: $wid (role=$role, wg=$wg_ip)"
    exit 0
    ;;
  heartbeat)
    [[ -n "$wid" ]] || { echo "erreur: id manquant"; exit 1; }
    tsv_update "$STATE_DIR/workers.tsv" 5 "$ts" 1 "$wid"
    tsv_update "$STATE_DIR/workers.tsv" 6 "alive" 1 "$wid"
    echo "heartbeat ok: $wid @ $ts"
    exit 0
    ;;
  result)
    [[ -n "$tid" ]] || { echo "erreur: task_id manquant"; exit 1; }
    [[ -n "$status" ]] || status="done"
    printf '%s' "$output" | sed 's/%20/ /g' > "$STATE_DIR/results/$tid"
    tsv_update "$STATE_DIR/tasks.tsv" 4 "$status" 1 "$tid"
    if [[ -f "$STATE_DIR/assignments.tsv" ]]; then
      awk -F'\t' -v t="$tid" '$1!=t' "$STATE_DIR/assignments.tsv" > "$STATE_DIR/assignments.tsv.tmp" && mv "$STATE_DIR/assignments.tsv.tmp" "$STATE_DIR/assignments.tsv"
    fi
    echo "résultat reçu: $tid → $status"
    exit 0
    ;;
  fetch)
    # Retourne la commande associée à un token
    local tok="$(get_param token)"
    [[ -n "$tok" ]] || { echo "erreur: token manquant"; exit 1; }
    local tline
    tline="$(tsv_find "$STATE_DIR/assignments.tsv" 1 "$tok")"
    if [[ -z "$tline" ]]; then
      echo "none"
      exit 0
    fi
    local task_id
    task_id="$(tsv_field "$tline" 2)"
    local cmdline
    cmdline="$(tsv_find "$STATE_DIR/tasks.tsv" 1 "$task_id" | tsv_field 3)"
    echo "$cmdline"
    exit 0
    ;;
esac

# --- Mode tokenisé : générer un token et retourner un script à | sh ---------

# Génère un token unique
TOKEN="$(uid | tr -d '.')"
EXPIRY=$(( ts + LEASE_TTL_SECONDS ))

# Cherche une tâche pending non assignée
TASK_LINE=""
while IFS=$'\t' read -r t tid client command status created; do
  [[ -z "$tid" ]] && continue
  [[ "$status" != "pending" ]] && continue
  if ! tsv_find "$STATE_DIR/assignments.tsv" 1 "$tid" | grep -q .; then
    TASK_LINE="$tid"$'\t'"$client"$'\t'"$command"
    break
  fi
done < "$STATE_DIR/tasks.tsv"

if [[ -z "$TASK_LINE" ]]; then
  echo "none"
  exit 0
fi

# Assigne la tâche au token
TASK_ID="$(printf '%s\n' "$TASK_LINE" | cut -f1)"
CLIENT="$(printf '%s\n' "$TASK_LINE" | cut -f2)"
COMMAND="$(printf '%s\n' "$TASK_LINE" | cut -f3-)"

tsv_append "$STATE_DIR/assignments.tsv" "$TOKEN" "$TASK_ID" "$ts"
tsv_update "$STATE_DIR/tasks.tsv" 4 "assigned" 1 "$TASK_ID"

# Décide si on vérifie (1 fois sur N=2, aléatoire)
VERIFY=0
if [ "$(( RANDOM % 2 ))" -eq 0 ]; then
  VERIFY=1
fi

# Marque si vérification requise
echo "$VERIFY" > "$STATE_DIR/assignments/$TOKEN.verify" 2>/dev/null || true

# Retourne un script à exécuter (| sh)
cat <<SCRIPT
#!/usr/bin/env bash
set -uo pipefail

# Script généré par beaut /give (token: $TOKEN)
# Ce script est exécuté par l'agent via | sh

TOKEN="$TOKEN"
DOMAIN="$DOMAIN"
HTTP_PORT="$HTTP_PORT"
LEASE_TTL=$LEASE_TTL_SECONDS
EXPIRY=$EXPIRY
VERIFY=$VERIFY

echo "Agent: token reçu \$TOKEN, expiration \$(date -d @\$EXPIRY 2>/dev/null || date)"

# 1. Demande la commande à exécuter au serveur
CMD_RESP="\$(curl -s -X POST "http://\$DOMAIN:\$HTTP_PORT/give" \
  -d "action=fetch&token=\$TOKEN")"

if [ "\$CMD_RESP" = "none" ] || [ -z "\$CMD_RESP" ]; then
  echo "Aucune commande disponible pour ce token."
  exit 1
fi

# 2. Exécute la commande
CMD_START=\$(date +%s)
CMD_OUTPUT="\$(bash -c "\$CMD_RESP" 2>&1)"
CMD_EXIT=\$?
CMD_END=\$(date +%s)

# 3. POSTe le résultat sur /done/<TOKEN> avant LEASE_TTL
NOW=\$(date +%s)
if [ "\$NOW" -lt "\$EXPIRY" ]; then
  curl -s -X POST "http://\$DOMAIN:\$HTTP_PORT/done/\$TOKEN" \
    -d "status=\$CMD_EXIT&output=\$(printf '%s' "\$CMD_OUTPUT" | sed 's/ /%20/g')&elapsed=\$(( CMD_END - CMD_START ))" \
    >/dev/null 2>&1
  echo "Résultat envoyé sur /done/\$TOKEN"
else
  echo "TOKEN expiré, résultat non envoyé."
fi

# 4. Si vérification requise, attendre le résultat d'un autre token
if [ "\$VERIFY" -eq 1 ]; then
  echo "Vérification croisée requise (1/N=2)."
fi

exit \$CMD_EXIT
SCRIPT
