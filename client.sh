#!/usr/bin/env bash
# client.sh — client donneur de tâches de beaut.
#
# Sous-commandes :
#   submit <commande>    soumet une commande au hub, affiche l'identifiant de tâche
#   status <task_id>     affiche le statut d'une tâche (pending/assigned/done/failed)
#   result <task_id>     affiche le résultat d'une tâche terminée
#   list                 liste workers et tâches
#
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/core.sh
. "$ROOT_DIR/lib/core.sh"
load_config "$@"

cmd="${1:-}"
shift || true

case "$cmd" in
  submit)
    command="$*"
    [[ -n "$command" ]] || { echo "usage: client.sh submit <commande>" >&2; exit 2; }
    ssh_hub submit client-local "$command"
    ;;
  status)
    tid="$1"
    [[ -n "$tid" ]] || { echo "usage: client.sh status <task_id>" >&2; exit 2; }
    tline=$(awk -F'\t' -v t="$tid" '$1==t{print; exit}' "$STATE_DIR/tasks.tsv" 2>/dev/null)
    if [[ -z "$tline" ]]; then echo "inconnue"; else
      awk -F'\t' -v t="$tid" '$1==t{print "tâche " $1 " — statut " $4 " — client " $2}' "$STATE_DIR/tasks.tsv"
    fi
    ;;
  result)
    tid="$1"
    [[ -n "$tid" ]] || { echo "usage: client.sh result <task_id>" >&2; exit 2; }
    if [[ -f "$STATE_DIR/results/$tid" ]]; then
      cat "$STATE_DIR/results/$tid"
    else
      echo "aucun résultat disponible pour $tid" >&2
      exit 1
    fi
    ;;
  list)
    ssh_hub list
    ;;
  *)
    echo "usage: client.sh {submit|status|result|list} ..." >&2; exit 2 ;;
esac
