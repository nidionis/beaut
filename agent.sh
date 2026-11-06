#!/usr/bin/env bash
# agent.sh — agent réparti (worker) de beaut.
#
# Sous-commandes :
#   register [id]      enregistre ce worker auprès du hub (clé publique + capacités)
#   heartbeat [id]     envoie un heartbeat au hub
#   run [id]           boucle principale : heartbeat → poll → exécute → résultat → sommeil
#
# L'agent s'authentifie par clé publique (WORKER_KEYS / ~/.ssh/*.pub) et s'exécute
# sans privilèges root, sur transport SSH pur vers le hub (cf. refonte.script).
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/core.sh
. "$ROOT_DIR/lib/core.sh"
load_config "$@"

CAPS="${WORKER_CAPS:-}"
PUBKEY_FILE="${WORKER_PUBKEY:-}"

# ---------- capacités de la machine ----------

detect_caps() {
  local nproc mem
  nproc=$(nproc 2>/dev/null || echo 1)
  mem=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
  printf 'cpu=%s mem_mib=%s' "$nproc" "$mem"
}

pubkey_of() {
  local id="$1"
  if [[ -n "$PUBKEY_FILE" && -f "$PUBKEY_FILE" ]]; then
    cat "$PUBKEY_FILE"; return
  fi
  if [[ -f "$WORKER_KEYS/$id" ]]; then
    cat "$WORKER_KEYS/$id"; return
  fi
  for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ecdsa.pub"; do
    [[ -f "$k" ]] && { cat "$k"; return; }
  done
  return 1
}

# ---------- sous-commandes ----------

cmd_register() {
  local caps="${CAPS:-$(detect_caps)}"
  local pk
  pk="$(pubkey_of "$WORKER_ID")" || { log error "aucune clé publique trouvée pour $WORKER_ID"; exit 2; }
  ssh_hub register "$WORKER_ID" "$pk" "$caps"
  log info "agent $WORKER_ID enregistré auprès du hub"
}

cmd_heartbeat() {
  ssh_hub heartbeat "$WORKER_ID"
}

run_task() {
  # run_task <task_id> <client> <command>
  local tid="$1" client="$2" command="$3"
  local tmpout status rc
  tmpout="$(mktemp)"
  log info "exécution de la tâche $tid (client=$client)"
  if timeout "$LEASE_TTL_SECONDS" bash -c "$command" >"$tmpout" 2>&1; then
    status=done
  else
    rc=$?
    status=failed
    log warn "tâche $tid terminée avec le code $rc"
  fi
  ssh_hub result "$WORKER_ID" "$tid" "$status" "$tmpout"
  rm -f "$tmpout"
}

cmd_run() {
  state_init
  # s'assurer d'être enregistré
  cmd_register >/dev/null 2>&1 || true
  log info "boucle agent démarrée (worker=$WORKER_ID, intervalle=${HEARTBEAT_INTERVAL}s)"
  while true; do
    cmd_heartbeat >/dev/null 2>&1 || true
    local payload
    payload="$(ssh_hub poll "$WORKER_ID")"
    if [[ "$payload" == "none" || -z "$payload" ]]; then
      sleep "$HEARTBEAT_INTERVAL"
      continue
    fi
    # payload : task_id \t client \t commande
    local tid client command
    IFS=$'\t' read -r tid client command <<<"$payload"
    [[ -n "$tid" ]] || continue
    run_task "$tid" "$client" "$command"
  done
}

# ---------- dispatcher ----------

cmd="${1:-}"
shift || true
WORKER_ID="${1:-$(hostname)}"

case "$cmd" in
  register)    cmd_register ;;
  heartbeat)   cmd_heartbeat ;;
  run)         cmd_run ;;
  *)           echo "usage: agent.sh {register|heartbeat|run} [worker_id]" >&2; exit 2 ;;
esac
