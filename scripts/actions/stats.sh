#!/usr/bin/env bash
# actions/stats.sh — endpoint /stats
# Affiche l'état du serveur : workers, tâches, assignations.
set -uo pipefail

ADIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BDIR="$(cd "$ADIR/.." && pwd)"
. "$BDIR/lib/core.sh"
load_config "$@"
# Re-établir ADIR après core.sh
ADIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

state_init

echo "=== beaut server stats ==="
echo "domaine: $DOMAIN"
echo "port HTTP: $HTTP_PORT"
echo "port WG: $WG_PORT"
echo
echo "--- workers ---"
if [[ -s "$STATE_DIR/workers.tsv" ]]; then
  column -t -s $'\t' "$STATE_DIR/workers.tsv" 2>/dev/null || cat "$STATE_DIR/workers.tsv"
else
  echo "(aucun worker)"
fi
echo
echo "--- tâches ---"
if [[ -s "$STATE_DIR/tasks.tsv" ]]; then
  column -t -s $'\t' "$STATE_DIR/tasks.tsv" 2>/dev/null || cat "$STATE_DIR/tasks.tsv"
else
  echo "(aucune tâche)"
fi
echo
echo "--- assignations ---"
if [[ -s "$STATE_DIR/assignments.tsv" ]]; then
  column -t -s $'\t' "$STATE_DIR/assignments.tsv" 2>/dev/null || cat "$STATE_DIR/assignments.tsv"
else
  echo "(aucune assignation)"
fi
