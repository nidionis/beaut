#!/usr/bin/env bash
# actions/give.sh — endpoint /give (POST)
# Le corps de la requête est transmis sur stdin par http_handler.sh.
# Actions : register, heartbeat, result
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
    ;;
  heartbeat)
    [[ -n "$wid" ]] || { echo "erreur: id manquant"; exit 1; }
    tsv_update "$STATE_DIR/workers.tsv" 5 "$ts" 1 "$wid"
    tsv_update "$STATE_DIR/workers.tsv" 6 "alive" 1 "$wid"
    echo "heartbeat ok: $wid @ $ts"
    ;;
  result)
    [[ -n "$tid" ]] || { echo "erreur: task_id manquant"; exit 1; }
    [[ -n "$status" ]] || status="done"
    # Sauvegarde le résultat (décodage URL simple)
    printf '%s' "$output" | sed 's/%20/ /g' > "$STATE_DIR/results/$tid"
    tsv_update "$STATE_DIR/tasks.tsv" 4 "$status" 1 "$tid"
    # Libère l'assignation
    if [[ -f "$STATE_DIR/assignments.tsv" ]]; then
      awk -F'\t' -v t="$tid" '$1!=t' "$STATE_DIR/assignments.tsv" > "$STATE_DIR/assignments.tsv.tmp" && mv "$STATE_DIR/assignments.tsv.tmp" "$STATE_DIR/assignments.tsv"
    fi
    echo "résultat reçu: $tid → $status"
    ;;
  *)
    echo "erreur: action inconnue '$action'"
    exit 1
    ;;
esac
