#!/usr/bin/env bash
# actions/install.sh — endpoint /install
# Retourne un script d'installation que le client exécute via `curl … | sh`.
# Le script télécharge l'agent, rejoint le WireGuard (clé publique du serveur
# transmise), s'enregistre, lance le watchdog.
set -uo pipefail

ADIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BDIR="$(cd "$ADIR/.." && pwd)"
. "$BDIR/lib/core.sh"
load_config "$@"

# Clé publique WireGuard du serveur (pour wg_join.sh)
SERVER_WG_PUB="$(cat "$STATE_DIR/wg_public.key" 2>/dev/null || echo '')"

cat <<INSTALL_SCRIPT
#!/usr/bin/env bash
set -uo pipefail

# Installation agent beaut sur ce nœud (via curl … | sh)
DOMAIN="${DOMAIN}"
HTTP_PORT="${HTTP_PORT}"
WG_PORT="${WG_PORT}"
STATE_DIR="\$HOME/.${NAME}/state"
SERVER_WG_PUB="${SERVER_WG_PUB}"

mkdir -p "\$STATE_DIR"
cd /tmp

echo "==> Téléchargement des scripts beaut"
curl -s "http://\$DOMAIN:\$HTTP_PORT/scripts/agent.sh"   -o /tmp/beaut_agent.sh
curl -s "http://\$DOMAIN:\$HTTP_PORT/scripts/lib/core.sh" -o /tmp/beaut_core.sh
curl -s "http://\$DOMAIN:\$HTTP_PORT/scripts/lib/http.sh" -o /tmp/beaut_http.sh
chmod +x /tmp/beaut_agent.sh /tmp/beaut_core.sh /tmp/beaut_http.sh

echo "==> Rejoindre le WireGuard"
if [ -n "\$SERVER_WG_PUB" ] && command -v wg >/dev/null 2>&1 && command -v ip >/dev/null 2>&1; then
  bash /tmp/beaut_core.sh >/dev/null 2>&1 || true
  # Génère les clés agent et rejoint le serveur WireGuard
  wg genkey | tee "\$STATE_DIR/wg_private.key" | wg pubkey > "\$STATE_DIR/wg_public.key"
  chmod 600 "\$STATE_DIR/wg_private.key"
  AGENT_PUB="\$(cat "\$STATE_DIR/wg_public.key")"
  WG_IP="10.66.0.\$((RANDOM % 254 + 2))"
  ip link del wg0 2>/dev/null || true
  ip link add wg0 type wireguard
  ip address add "\$WG_IP/24" dev wg0
  wg set wg0 private-key "\$STATE_DIR/wg_private.key"
  wg set wg0 peer "\$SERVER_WG_PUB" endpoint "\$DOMAIN:\$WG_PORT" allowed-ips "${WG_NET}" persistent-keepalive 25
  ip link set wg0 up
  echo "WireGuard actif : \$WG_IP"
else
  echo "ATTENTION: wg/ip indisponibles, WireGuard non configuré."
fi

echo "==> Enregistrement auprès du serveur (/give)"
WORKER_ID="\$(hostname)"
PUB_KEY="\$(cat \$STATE_DIR/wg_public.key 2>/dev/null || echo inconnu)"
WG_IP="\$(ip address show wg0 2>/dev/null | awk '/inet /{print \$2}' | cut -d/ -f1)"
curl -s -X POST "http://\$DOMAIN:\$HTTP_PORT/give" \
  -d "action=register&id=\$WORKER_ID&pubkey=\$PUB_KEY&wg_ip=\$WG_IP&role=guest" >/dev/null 2>&1 || true

echo "==> Lancement de l'agent"
nohup bash /tmp/beaut_agent.sh run "\$WORKER_ID" > "\$STATE_DIR/agent.log" 2>&1 &

echo "Agent beaut installé et démarré sur \$WORKER_ID (WG: \$WG_IP)"
INSTALL_SCRIPT
