#!/usr/bin/env bash
# client.sh — client donneur de tâches.
# Sous-commandes : submit status result list
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
. "$SCRIPTS_DIR/lib/core.sh"
load_config "$@"

cmd="${1:-}"; shift || true

case "$cmd" in
  submit)
    command="$*"; [[ -n "$command" ]] || { echo "usage: client.sh submit <commande>" >&2; exit 2; }
    ssh_hub submit client-local "$command" ;;
  status)
    tid="$1"; [[ -n "$tid" ]] || { echo "usage: client.sh status <task_id>" >&2; exit 2; }
    tline=$(awk -F'\t' -v t="$tid" '$1==t{print; exit}' "$STATE_DIR/tasks.tsv" 2>/dev/null)
    if [[ -z "$tline" ]]; then echo "inconnue"; else
      awk -F'\t' -v t="$tid" '$1==t{print "tâche " $1 " — statut " $4}' "$STATE_DIR/tasks.tsv"
    fi ;;
  result)
    tid="$1"; [[ -n "$tid" ]] || { echo "usage: client.sh result <task_id>" >&2; exit 2; }
    if [[ -f "$STATE_DIR/results/$tid" ]]; then cat "$STATE_DIR/results/$tid";
    else echo "aucun résultat pour $tid" >&2; exit 1; fi ;;
  list) ssh_hub list ;;
  *) echo "usage: client.sh {submit|status|result|list} ..." >&2; exit 2 ;;
esac
