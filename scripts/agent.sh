#!/usr/bin/env bash
# agent.sh — agent réparti (worker).
# Fonctions : agent_register agent_heartbeat agent_ask agent_run agent_watchdog
# Sourcé par beaut.sh ; auto-exécution si lancé directement.
set -uo pipefail

HDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HDIR/lib/core.sh"
load_config "$@"

WORKER_ID="${WORKER_ID:-$(hostname)}"

agent_register() {
  local pubkey wg_ip role
  pubkey="$(cat "$STATE_DIR/wg_public.key" 2>/dev/null || echo inconnu)"
  wg_ip="$(ip address show wg0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)"
  role="${AGENT_ROLE:-guest}"
  log info "enregistrement du worker $WORKER_ID (role=$role, wg=$wg_ip)"
  local i resp
  for ((i=0; i<30; i++)); do
    resp="$(curl -s -X POST "http://127.0.0.1:$HTTP_PORT/give" \
      -d "action=register&id=$WORKER_ID&pubkey=$pubkey&wg_ip=$wg_ip&role=$role")"
    log info "tentative $i: $(printf '%s' "$resp" | head -1)"
    printf '%s' "$resp" | grep -q "enregistré" && return 0
    sleep 1
  done
  log error "échec enregistrement après 30 tentatives"
  return 1
}

agent_heartbeat() {
  local resp
  resp="$(curl -s -X POST "http://127.0.0.1:$HTTP_PORT/give" \
    -d "action=heartbeat&id=$WORKER_ID")"
  printf '%s' "$resp" | grep -q "enregistré\|heartbeat ok" && return 0
  return 1
}

agent_ask() {
  local payload tid client command nice
  payload="$(curl -s "http://127.0.0.1:$HTTP_PORT/ask?id=$WORKER_ID")"
  [[ "$payload" == "none" || -z "$payload" ]] && { echo "none"; return 1; }
  IFS=$'\t' read -r tid client command <<<"$payload"
  nice="$(worker_nice "$WORKER_ID")"
  printf '%s\t%s\t%s\t%s\n' "$tid" "$client" "$command" "$nice"
}

agent_run_task() {
  local tid="$1" client="$2" command="$3" nice="$4"
  local tmpout status rc
  tmpout="$(mktemp)"
  log info "exécution de la tâche $tid (nice=$nice) par $WORKER_ID"

  if timeout "$LEASE_TTL_SECONDS" nice -n "$nice" bash -c "$command" >"$tmpout" 2>&1; then
    status=done
  else
    rc=$?
    status=failed
    log warn "tâche $tid terminée avec le code $rc"
  fi

  # Rapport du résultat via /give (POST)
  local encoded_output
  encoded_output="$(printf '%s' "$(cat "$tmpout")" | sed 's/ /%20/g')"
  curl -s -X POST "http://127.0.0.1:$HTTP_PORT/give" \
    -d "action=result&task_id=$tid&task_status=$status&output=$encoded_output" >/dev/null 2>&1 || true
  log info "résultat $tid envoyé"
  rm -f "$tmpout"
}

agent_watchdog() {
  # Maintient en vie un service : docker, systemctl, cron, ou commande simple
  local service="${WATCHDOG_SERVICE:-}"
  local cmd="${WATCHDOG_CMD:-}"
  while true; do
    if [[ -n "$service" ]]; then
      if cmd_exists docker && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^$service$"; then
        :
      elif cmd_exists systemctl && systemctl is-active --quiet "$service" 2>/dev/null; then
        :
      else
        log warn "watchdog: redémarrage de $service"
        cmd_exists docker && docker start "$service" 2>/dev/null || true
        cmd_exists systemctl && systemctl start "$service" 2>/dev/null || true
      fi
    elif [[ -n "$cmd" ]]; then
      pgrep -f "$cmd" >/dev/null 2>&1 || { log info "watchdog: relance de $cmd"; nohup bash -c "$cmd" >/dev/null 2>&1 & }
    fi
    sleep "${WATCHDOG_INTERVAL:-30}"
  done
}

agent_run() {
  state_init
  agent_register
  log info "boucle agent démarrée (worker=$WORKER_ID, intervalle=${HEARTBEAT_INTERVAL}s)"

  if [[ -n "${WATCHDOG_SERVICE:-}${WATCHDOG_CMD:-}" ]]; then
    agent_watchdog &
  fi

  while true; do
    agent_heartbeat
    local task_line
    task_line="$(agent_ask)" || { sleep "$HEARTBEAT_INTERVAL"; continue; }
    IFS=$'\t' read -r tid client command nice <<<"$task_line"
    [[ -n "$tid" ]] && agent_run_task "$tid" "$client" "$command" "$nice"
    sleep "$HEARTBEAT_INTERVAL"
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"; shift || true
  case "$cmd" in
    register) agent_register ;;
    heartbeat) agent_heartbeat ;;
    ask) agent_ask ;;
    run) agent_run ;;
    watchdog) agent_watchdog ;;
    *) echo "usage: agent.sh {register|heartbeat|ask|run|watchdog}" >&2; exit 2 ;;
  esac
fi
