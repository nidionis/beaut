#!/usr/bin/env bash
# agent.sh — agent réparti (worker).
# Sous-commandes : register heartbeat run
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
. "$SCRIPTS_DIR/lib/core.sh"
load_config "$@"

CAPS="${WORKER_CAPS:-}"
PUBKEY_FILE="${WORKER_PUBKEY:-}"

detect_caps() {
  local nproc mem; nproc=$(nproc 2>/dev/null || echo 1)
  mem=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
  printf 'cpu=%s mem_mib=%s' "$nproc" "$mem"
}

pubkey_of() {
  local id="$1"
  [[ -n "$PUBKEY_FILE" && -f "$PUBKEY_FILE" ]] && { cat "$PUBKEY_FILE"; return; }
  [[ -f "$WORKER_KEYS/$id" ]] && { cat "$WORKER_KEYS/$id"; return; }
  for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ecdsa.pub"; do
    [[ -f "$k" ]] && { cat "$k"; return; }
  done
  return 1
}

cmd_register() {
  local caps="${CAPS:-$(detect_caps)}"; local pk
  pk="$(pubkey_of "$WORKER_ID")" || { log error "aucune clé publique pour $WORKER_ID"; exit 2; }
  ssh_hub register "$WORKER_ID" "$pk" "$caps"
  log info "agent $WORKER_ID enregistré"
}

cmd_heartbeat() { ssh_hub heartbeat "$WORKER_ID"; }

run_task() {
  local tid="$1" client="$2" command="$3"
  local tmpout; tmpout="$(mktemp)"
  log info "exécution tâche $tid (client=$client)"
  if timeout "$LEASE_TTL_SECONDS" bash -c "$command" >"$tmpout" 2>&1; then
    ssh_hub result "$WORKER_ID" "$tid" done "$tmpout"
  else
    ssh_hub result "$WORKER_ID" "$tid" failed "$tmpout"
  fi
  rm -f "$tmpout"
}

cmd_run() {
  state_init
  cmd_register >/dev/null 2>&1 || true
  log info "boucle agent (worker=$WORKER_ID, intervalle=${HEARTBEAT_INTERVAL}s)"
  while true; do
    cmd_heartbeat >/dev/null 2>&1 || true
    local payload; payload="$(ssh_hub poll "$WORKER_ID")"
    [[ "$payload" == "none" || -z "$payload" ]] && { sleep "$HEARTBEAT_INTERVAL"; continue; }
    local tid client command; IFS=$'\t' read -r tid client command <<<"$payload"
    [[ -n "$tid" ]] && run_task "$tid" "$client" "$command"
  done
}

cmd="${1:-}"; shift || true
WORKER_ID="${1:-$(hostname)}"
case "$cmd" in
  register) cmd_register ;;
  heartbeat) cmd_heartbeat ;;
  run) cmd_run ;;
  *) echo "usage: agent.sh {register|heartbeat|run} [worker_id]" >&2; exit 2 ;;
esac
