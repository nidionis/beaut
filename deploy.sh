#!/usr/bin/env bash
# deploy.sh — point d'entrée unique de beaut.
set -uo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$DEPLOY_DIR/scripts"

. "$DEPLOY_DIR/config.env" 2>/dev/null || . "$DEPLOY_DIR/config.env.example"
[[ -f "$DEPLOY_DIR/.env" ]] && . "$DEPLOY_DIR/.env"
export NAME DIR STATE_DIR DOMAIN HTTP_PORT WG_PORT WG_NET WG_SERVER_IP \
  LEASE_TTL_SECONDS HEARTBEAT_INTERVAL WORKER_STALE_SECONDS LOG_LEVEL \
  NICE_ROOT NICE_VIP NICE_GUEST

# Source les libs et scripts (SCRIPS_DIR est préservé par core.sh)
. "$SCRIPTS_DIR/lib/core.sh"
SCRIPTS_DIR="$DEPLOY_DIR/scripts"
. "$SCRIPTS_DIR/lib/http.sh"
. "$SCRIPTS_DIR/agent.sh"
. "$SCRIPTS_DIR/client.sh"

BEAUT_BIN="/usr/local/bin/beaut.sh"

usage() { echo "usage: deploy.sh {server|agent|install|demo|init|status|list}"; echo
  echo "  server   — lance WireGuard + serveur HTTP (doit tourner sur DOMAIN)"
  echo "  agent    — lance un agent worker (pull-based)"
  echo "  install  — installe beaut.sh dans le PATH (ou local si pas de droits root)"
  echo "  demo     — démo complète : serveur + agent + tâche docker-compose hello-world"
  echo "  init     — initialise l'état (state/)"
  echo "  status   — affiche les stats du serveur"
  echo "  list     — alias de status"; }

cmd_init() { state_init; log info "état initialisé dans $STATE_DIR"; }

cmd_server() {
  cmd_init
  log info "démarrage WireGuard serveur"
  bash "$SCRIPTS_DIR/wg_setup.sh"
  log info "démarrage serveur HTTP sur $DOMAIN:$HTTP_PORT"
  bash "$SCRIPTS_DIR/http_server.sh"
}

cmd_agent() {
  local wid="${1:-$(hostname)}"
  export WORKER_ID="$wid"
  bash "$SCRIPTS_DIR/agent.sh" run "$wid"
}

cmd_install() {
  local target
  if [[ -w /usr/local/bin ]] || (sudo -n true 2>/dev/null); then
    target="$BEAUT_BIN"
    log info "installation de beaut.sh dans $target"
  else
    target="$DEPLOY_DIR/beaut.sh"
    log info "pas de droits root — installation locale dans $target"
  fi

  cat > "$target" <<BEAUT_SCRIPT
#!/usr/bin/env bash
# beaut.sh — point d'entrée utilisateur de beaut
set -uo pipefail

ROOT_DIR="$DEPLOY_DIR"
SCRIPS_DIR="\$ROOT_DIR/scripts"
. "\$ROOT_DIR/config.env" 2>/dev/null || . "\$ROOT_DIR/config.env.example"
[[ -f "\$ROOT_DIR/.env" ]] && . "\$ROOT_DIR/.env"
export NAME DIR STATE_DIR DOMAIN HTTP_PORT WG_PORT WG_NET WG_SERVER_IP \
  LEASE_TTL_SECONDS HEARTBEAT_INTERVAL WORKER_STALE_SECONDS LOG_LEVEL \
  NICE_ROOT NICE_VIP NICE_GUEST

. "\$SCRIPS_DIR/lib/core.sh"
SCRIPS_DIR="\$ROOT_DIR/scripts"
. "\$SCRIPS_DIR/lib/http.sh"

cmd="\${1:-}"; shift || true

case "\$cmd" in
  server)
    state_init
    bash "\$SCRIPS_DIR/wg_setup.sh"
    bash "\$SCRIPS_DIR/http_server.sh"
    ;;
  agent)
    export WORKER_ID="\${1:-\$(hostname)}"
    bash "\$SCRIPS_DIR/agent.sh" run "\$WORKER_ID"
    ;;
  demo)
    echo "=== Démo beaut ==="
    state_init
    bash "\$SCRIPS_DIR/wg_setup.sh" &
    sleep 1
    bash "\$SCRIPS_DIR/http_server.sh" &
    SRV_PID=\$!
    sleep 2
    echo "Serveur lancé (PID \$SRV_PID)"
    echo
    echo "Pour installer un agent sur un autre nœud :"
    echo "  curl http://\$DOMAIN:\$HTTP_PORT/install | sh"
    echo
    echo "Pour soumettre une tâche :"
    echo "  beaut.sh submit 'echo hello-world'"
    echo
    echo "Pour voir les stats :"
    echo "  beaut.sh status"
    echo
    kill \$SRV_PID 2>/dev/null
    ;;
  init) state_init ;;
  status|list) curl -s "\$DOMAIN:\$HTTP_PORT/stats" ;;
  submit)
    command="\$*"
    [[ -n "\$command" ]] || { echo "usage: beaut.sh submit <commande>" >&2; exit 2; }
    local_stats="\$(curl -s "\$DOMAIN:\$HTTP_PORT/stats")"
    echo "ressources: \$local_stats"
    tid="\$(uid)"
    tsv_append "\$STATE_DIR/tasks.tsv" "\$tid" "client-local" "\$command" "pending" "\$(date +%s)"
    echo "tâche soumise: \$tid"
    ;;
  *)
    echo "usage: beaut.sh {server|agent|demo|init|status|list|submit} [args...]"
    exit 2
    ;;
esac
BEAUT_SCRIPT
  chmod +x "$target"
  log info "beaut.sh installé dans $target"
}

cmd_demo() {
  cmd_install
  cmd_init

  # Nettoie d'éventuels serveurs précédents
  pkill -f 'scripts/http_server.sh' 2>/dev/null || true
  pkill -f 'socat TCP-LISTEN' 2>/dev/null || true
  fuser -k "$HTTP_PORT"/tcp 2>/dev/null || true
  sleep 1

  # Pour la démo locale, on force DOMAIN=127.0.0.1
  export DOMAIN=127.0.0.1

  # Lance le serveur en arrière-plan
  log info "lancement du serveur en arrière-plan"
  bash "$SCRIPTS_DIR/wg_setup.sh" > "$STATE_DIR/wg.log" 2>&1 &
  sleep 1
  bash "$SCRIPTS_DIR/http_server.sh" > "$STATE_DIR/http.log" 2>&1 &
  SRV_PID=$!
  for ((i=0; i<30; i++)); do
    if ss -tlnp | grep -q ":$HTTP_PORT "; then
      break
    fi
    sleep 0.5
  done
  sleep 1

  echo "=== Serveur démarré (PID $SRV_PID) ==="
  echo "URL: http://$DOMAIN:$HTTP_PORT"
  echo

  # Lance un agent local avec intervalle court pour la démo
  log info "lancement d'un agent local"
  export WORKER_ID="demo-worker"
  export HEARTBEAT_INTERVAL=1
  bash "$SCRIPTS_DIR/agent.sh" run "demo-worker" > "$STATE_DIR/agent.log" 2>&1 &
  AGENT_PID=$!
  sleep 3

  # Crée un exemple docker-compose hello-world
  DEMO_DIR="$STATE_DIR/demo"
  mkdir -p "$DEMO_DIR"
  cat > "$DEMO_DIR/docker-compose.yml" <<'COMPOSE'
version: '3'
services:
  hello:
    image: alpine:latest
    command: echo "Hello World from Docker Compose via beaut!"
COMPOSE

  # Soumet une tâche : lancer le docker-compose
  TASK_CMD="cd $DEMO_DIR && docker-compose up 2>/dev/null || echo 'docker-compose non disponible, exécution simple' && echo hello-beaut-demo"
  log info "soumission de la tâche : $TASK_CMD"
  TASK_ID=$(client_submit "$TASK_CMD" 2>/dev/null | tail -1)
  echo "task_id=$TASK_ID"

  sleep 8

  echo "=== Statut ==="
  client_status "$TASK_ID"
  echo
  echo "=== Résultat ==="
  client_result "$TASK_ID"
  echo

  # Arrêt
  kill "$AGENT_PID" "$SRV_PID" 2>/dev/null
  wait 2>/dev/null
  log info "démo terminée"
}

cmd_status() { curl -s "http://$DOMAIN:$HTTP_PORT/stats"; }
cmd_list() { cmd_status; }

cmd="${1:-}"; shift || true
case "$cmd" in
  server) cmd_server ;;
  agent)  cmd_agent "$@" ;;
  install) cmd_install ;;
  demo)   cmd_demo ;;
  init)   cmd_init ;;
  status) cmd_status ;;
  list)   cmd_list ;;
  *)      usage; exit 2 ;;
esac
