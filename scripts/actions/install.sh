#!/usr/bin/env bash
# actions/install.sh — endpoint /install
# Renvoie un script d'installation que le client exécute via `curl … | sh`.
# L'agent s'installe, rejoint le WireGuard, s'enregistre, lance le watchdog.
set -uo pipefail

ADIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BDIR="$(cd "$ADIR/.." && pwd)"
. "$BDIR/lib/core.sh"
load_config "$@"

cat <<INSTALL_SCRIPT
#!/usr/bin/env bash
set -uo pipefail

# Installation agent beaut sur ce nœud
DOMAIN="${DOMAIN}"
HTTP_PORT="${HTTP_PORT}"
WG_PORT="${WG_PORT}"
WG_SERVER_IP="${WG_SERVER_IP}"
STATE_DIR="\$HOME/.${NAME}/state"

mkdir -p "\$STATE_DIR"
cd /tmp

# 1. Télécharge les scripts depuis le serveur
curl -s "http://\$DOMAIN:\$HTTP_PORT/scripts/agent.sh" -o /tmp/beaut_agent.sh
curl -s "http://\$DOMAIN:\$HTTP_PORT/scripts/lib/core.sh" -o /tmp/beaut_core.sh
curl -s "http://\$DOMAIN:\$HTTP_PORT/scripts/lib/http.sh" -o /tmp/beaut_http.sh
chmod +x /tmp/beaut_agent.sh /tmp/beaut_core.sh /tmp/beaut_http.sh

# 2. Rejoint le WireGuard (clé publique serveur requise)
echo "Clé publique du serveur nécessaire pour rejoindre le VPN."
echo "Récupérez-la sur le serveur puis relancez avec :"
echo "  wg_join.sh <serveur_pub_key>"

# 3. Enregistrement auprès du serveur via /give
WORKER_ID="\$(hostname)"
WG_IP="\$(ip address show wg0 2>/dev/null | awk '/inet /{print \$2}' | cut -d/ -f1)"
PUB_KEY="\$(cat \$STATE_DIR/wg_public.key 2>/dev/null || echo inconnu)"

curl -s -X POST "http://\$DOMAIN:\$HTTP_PORT/give" \
  -d "action=register&id=\$WORKER_ID&pubkey=\$PUB_KEY&wg_ip=\$WG_IP&role=guest" >/dev/null 2>&1 || true

# 4. Lance l'agent en boucle
nohup bash /tmp/beaut_agent.sh run "\$WORKER_ID" > "\$STATE_DIR/agent.log" 2>&1 &

echo "Agent beaut installé et démarré sur \$WORKER_ID (WG: \$WG_IP)"
INSTALL_SCRIPT
