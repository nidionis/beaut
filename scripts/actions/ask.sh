#!/usr/bin/env bash
# actions/ask.sh — endpoint /ask
# Un agent demande une tâche. Le serveur renvoie la prochaine tâche pending
# affectée à ce worker, ou "none".
# L'ID du worker passe en query string : /ask?id=demo-worker
# Le worker doit figurer dans workers.trusted pour recevoir des tâches.
set -uo pipefail

ADIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BDIR="$(cd "$ADIR/.." && pwd)"
. "$BDIR/lib/core.sh"
load_config "$@"
# Re-établir ADIR après core.sh
ADIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$BDIR/lib/trusted.sh"

state_init

# Lire les en-têtes HTTP depuis stdin (ligne par ligne jusqu'à ligne vide)
headers=""
while IFS= read -r -t 5 line; do
    line="${line%$'\r'}"
    headers+="$line"$'\n'
    [[ -z "$line" ]] && break
done

# Extraire l'ID du worker depuis l'URL ?id=demo-worker
first_line="$(printf '%s\n' "$headers" | head -n1)"
path="$(printf '%s\n' "$first_line" | awk '{print $2}')"
WORKER_ID="$(printf '%s\n' "$path" | awk -F'[?&]' '{for(i=1;i<=NF;i++){split($i,a,"="); if(a[1]=="id"){print a[2]; exit}}}')"
[[ -z "$WORKER_ID" ]] && WORKER_ID="$(hostname)"

# Vérifier que le worker est dans la liste de confiance
TRUSTED_FILE="$STATE_DIR/workers.trusted"
if [[ -s "$TRUSTED_FILE" ]]; then
  trusted_ip="$(trusted_ip "$TRUSTED_FILE" "$WORKER_ID")"
  if [[ -z "$trusted_ip" ]]; then
    echo "none"
    exit 0
  fi
fi

# Marquer les workers stale (colonne 5 = last_seen, colonne 6 = statut)
now="$(date +%s)"
cutoff=$(( now - WORKER_STALE_SECONDS ))
tsv_mark_stale "$STATE_DIR/workers.tsv" "$cutoff"

# Tâches pending non encore assignées (seulement statut "pending")
while IFS=$'\t' read -r tid client command status created; do
  [[ -z "$tid" ]] && continue
  [[ "$status" != "pending" ]] && continue
  # Vérifie qu'elle n'est pas déjà assignée
  if ! tsv_find "$STATE_DIR/assignments.tsv" 1 "$tid" | grep -q .; then
    # Assigne à ce worker
    ats="$(date +%s)"
    tsv_append "$STATE_DIR/assignments.tsv" "$tid" "$WORKER_ID" "$ats"
    tsv_update "$STATE_DIR/tasks.tsv" 4 "assigned" 1 "$tid"
    # Renvoie la tâche à l'agent
    printf '%s\t%s\t%s\n' "$tid" "$client" "$command"
    exit 0
  fi
done < "$STATE_DIR/tasks.tsv"

echo "none"
