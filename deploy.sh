#!/usr/bin/env bash
# deploy.sh — installation / déploiement / démonstration de beaut.
# Source config.env, puis pilote hub.sh / agent.sh / client.sh.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$ROOT_DIR/config.env" 2>/dev/null || . "$ROOT_DIR/config.env.example"
[[ -f "$ROOT_DIR/.env" ]] && . "$ROOT_DIR/.env"
export NAME DIR STATE_DIR HUB_HOST HUB_PORT HUB_USER \
  WORKER_STALE_SECONDS HEARTBEAT_INTERVAL LEASE_TTL_SECONDS LOG_LEVEL \
  CLIENT_KEYS WORKER_KEYS

SCRIPTS="$ROOT_DIR/scripts"

usage() { echo "usage: deploy.sh {init|up|down|demo}"; echo
  echo "  init  — initialise l'état (state/)"
  echo "  up    — lance le hub (daemon) + un agent en arrière-plan"
  echo "  down  — arrête hub et agent"
  echo "  demo  — up, soumet une tâche (HTTP serveur sur un dossier hello world), affiche le résultat"; }

cmd_init() { bash "$SCRIPTS/hub.sh" init; }

cmd_up() {
  bash "$SCRIPTS/hub.sh" init
  bash "$SCRIPTS/agent.sh" register "${WORKER_ID:-$(hostname)}"
  nohup bash "$SCRIPTS/hub.sh" daemon   > "$STATE_DIR/daemon.log" 2>&1 &
  nohup bash "$SCRIPTS/agent.sh" run "${WORKER_ID:-$(hostname)}" > "$STATE_DIR/agent.log" 2>&1 &
  echo "hub + agent lancé (état dans $STATE_DIR)"
}

cmd_down() {
  pkill -f 'scripts/hub.sh daemon' 2>/dev/null
  pkill -f 'scripts/agent.sh run' 2>/dev/null
  echo "arrêté"
}

cmd_demo() {
  export HEARTBEAT_INTERVAL=1
  cmd_up
  sleep 2
  SHARED="$STATE_DIR/demo"
  mkdir -p "$SHARED"
  echo "Hello World" > "$SHARED/index.html"
  TASK_ID=$(bash "$SCRIPTS/client.sh" submit \
    "mkdir -p $SHARED && echo 'Hello World' > $SHARED/index.html && timeout 3 python3 -m http.server 8000 --directory $SHARED; echo SERVED:$SHARED")
  echo "task_id=$TASK_ID"
  sleep 6
  echo "=== statut ==="
  bash "$SCRIPTS/client.sh" status "$TASK_ID"
  echo "=== résultat ==="
  bash "$SCRIPTS/client.sh" result "$TASK_ID"
  echo "=== dossier partagé (hello world) ==="
  cat "$SHARED/index.html"
  echo
  echo "Pour lancer le serveur HTTP vous-même :"
  echo "  python3 -m http.server 8000 --directory $SHARED"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  init) cmd_init ;;
  up)   cmd_up ;;
  down) cmd_down ;;
  demo) cmd_demo ;;
  *)    usage; exit 2 ;;
esac
