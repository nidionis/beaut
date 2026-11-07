#!/usr/bin/env bash
# beaut.sh — point d'entrée utilisateur de beaut
set -uo pipefail

ROOT_DIR="/home/pain/code/beaut"
SCRIPS_DIR="$ROOT_DIR/scripts"
. "$ROOT_DIR/config.env" 2>/dev/null || . "$ROOT_DIR/config.env.example"
[[ -f "$ROOT_DIR/.env" ]] && . "$ROOT_DIR/.env"
export NAME DIR STATE_DIR DOMAIN HTTP_PORT WG_PORT WG_NET WG_SERVER_IP   LEASE_TTL_SECONDS HEARTBEAT_INTERVAL WORKER_STALE_SECONDS LOG_LEVEL   NICE_ROOT NICE_VIP NICE_GUEST

. "$SCRIPS_DIR/lib/core.sh"
SCRIPS_DIR="$ROOT_DIR/scripts"
. "$SCRIPS_DIR/lib/http.sh"

cmd="${1:-}"; shift || true

case "$cmd" in
  server)
    state_init
    bash "$SCRIPS_DIR/wg_setup.sh"
    bash "$SCRIPS_DIR/http_server.sh"
    ;;
  agent)
    export WORKER_ID="${1:-$(hostname)}"
    bash "$SCRIPS_DIR/agent.sh" run "$WORKER_ID"
    ;;
  demo)
    echo "=== Démo beaut ==="
    state_init
    bash "$SCRIPS_DIR/wg_setup.sh" &
    sleep 1
    bash "$SCRIPS_DIR/http_server.sh" &
    SRV_PID=$!
    sleep 2
    echo "Serveur lancé (PID $SRV_PID)"
    echo
    echo "Pour installer un agent sur un autre nœud :"
    echo "  curl http://$DOMAIN:$HTTP_PORT/install | sh"
    echo
    echo "Pour soumettre une tâche :"
    echo "  beaut.sh submit 'echo hello-world'"
    echo
    echo "Pour voir les stats :"
    echo "  beaut.sh status"
    echo
    kill $SRV_PID 2>/dev/null
    ;;
  init) state_init ;;
  status|list) curl -s "$DOMAIN:$HTTP_PORT/stats" ;;
  submit)
    command="$*"
    [[ -n "$command" ]] || { echo "usage: beaut.sh submit <commande>" >&2; exit 2; }
    local_stats="$(curl -s "$DOMAIN:$HTTP_PORT/stats")"
    echo "ressources: $local_stats"
    tid="$(uid)"
    tsv_append "$STATE_DIR/tasks.tsv" "$tid" "client-local" "$command" "pending" "$(date +%s)"
    echo "tâche soumise: $tid"
    ;;
  *)
    echo "usage: beaut.sh {server|agent|demo|init|status|list|submit} [args...]"
    exit 2
    ;;
esac
