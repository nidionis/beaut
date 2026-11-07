#!/usr/bin/env bash
# client.sh — client donneur de tâches.
# Requêtes dynamiques : interroge /stats puis envoie une commande via /give.
set -uo pipefail

HDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HDIR/lib/core.sh"
load_config "$@"

client_submit() {
  local command="$*"
  [[ -n "$command" ]] || { echo "usage: client_submit <commande>" >&2; exit 2; }

  # 1. Demande les ressources disponibles
  local stats
  stats="$(curl -s "http://127.0.0.1:$HTTP_PORT/stats")"
  log info "ressources serveur: $stats"

  # 2. Soumet la tâche via /give (enregistrement d'une tâche pending)
  local tid; tid="$(uid)"
  tsv_append "$STATE_DIR/tasks.tsv" "$tid" "client-local" "$command" "pending" "$(date +%s)"
  echo "$tid"
}

client_status() {
  local tid="$1"; [[ -n "$tid" ]] || { echo "usage: client_status <task_id>" >&2; exit 2; }
  local line; line="$(tsv_find "$STATE_DIR/tasks.tsv" 1 "$tid")"
  if [[ -z "$line" ]]; then echo "inconnue"; else
    tsv_field "$line" 4
  fi
}

client_result() {
  local tid="$1"; [[ -n "$tid" ]] || { echo "usage: client_result <task_id>" >&2; exit 2; }
  if [[ -f "$STATE_DIR/results/$tid" ]]; then cat "$STATE_DIR/results/$tid";
  else echo "aucun résultat pour $tid" >&2; exit 1; fi
}

client_list() { curl -s "http://127.0.0.1:$HTTP_PORT/stats"; }

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"; shift || true
  case "$cmd" in
    submit) client_submit "$@" ;;
    status) client_status "$1" ;;
    result) client_result "$1" ;;
    list) client_list ;;
    *) echo "usage: client.sh {submit|status|result|list} ..." >&2; exit 2 ;;
  esac
fi
