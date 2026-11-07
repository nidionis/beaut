#!/usr/bin/env bash
# deploy.sh — installation du serveur de contrôle beaut sur l'hôte (root requis).
#
# Ce script ne fait qu'une chose : préparer l'hôte pour qu'il serve de point de
# contrôle (le "C2 légal"). Il doit être exécuté une fois, avec des privilèges
# root, sur la machine qui portera DOMAIN:$HTTP_PORT.
#
# Aucune tâche n'est soumise ici, aucun agent n'est lancé. Ce fichier installe
# uniquement l'infrastructure serveur : WireGuard + serveur HTTP + service au
# démarrage. Toute configuration ultérieure se fait dans config.env.
#
# Usage : sudo ./deploy.sh

set -uo pipefail

[[ $EUID -eq 0 ]] || { echo "deploy.sh doit être lancé en root (sudo ./deploy.sh)" >&2; exit 1; }

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$DEPLOY_DIR/scripts"

# Charge la config (commentée, éditable à la main)
. "$DEPLOY_DIR/config.env" 2>/dev/null || . "$DEPLOY_DIR/config.env.example"
[[ -f "$DEPLOY_DIR/.env" ]] && . "$DEPLOY_DIR/.env"
export NAME DIR STATE_DIR DOMAIN HTTP_PORT WG_PORT WG_NET WG_SERVER_IP \
  LEASE_TTL_SECONDS HEARTBEAT_INTERVAL WORKER_STALE_SECONDS LOG_LEVEL \
  NICE_ROOT NICE_VIP NICE_GUEST

# Source les libs (SCRIPS_DIR est préservé par core.sh)
. "$SCRIPTS_DIR/lib/core.sh"
SCRIPTS_DIR="$DEPLOY_DIR/scripts"

echo "=== Installation du serveur beaut sur $DOMAIN:$HTTP_PORT ==="
echo

# --- 1. Répertoire d'état ---
echo "[1/6] Création du répertoire d'état ($STATE_DIR)"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# --- 2. WireGuard (nécessite root) ---
echo "[2/6] Configuration de WireGuard"
bash "$SCRIPTS_DIR/wg_setup.sh"
echo "Clé publique WireGuard : $(cat "$STATE_DIR/wg_public.key")"
echo

# --- 3. Service au démarrage (nécessite root) ---
echo "[3/6] Installation du service au démarrage"
SERVICE_FILE="/etc/systemd/system/beaut.service"
cat > "$SERVICE_FILE" <<SVCEOF
[Unit]
Description=beaut serveur de contrôle (pull-based)
After=network.target

[Service]
Type=simple
WorkingDirectory=$DEPLOY_DIR
ExecStart=$DEPLOY_DIR/scripts/http_server.sh
Restart=always
User=$SUDO_USER

[Install]
WantedBy=multi-user.target
SVCEOF

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
  systemctl enable beaut.service
  systemctl start beaut.service
  echo "Service systemd 'beaut' activé et démarré."
else
  echo "ATTENTION: systemctl non trouvé. Le service n'a pas été installé au démarrage."
  echo "Lancez manuellement : $DEPLOY_DIR/scripts/http_server.sh &"
fi
echo

# --- 4. Ouverture du port HTTP (nécessite root) ---
echo "[4/6] Ouverture du port HTTP ($HTTP_PORT)"
if command -v nft >/dev/null 2>&1; then
  nft add rule inet beaut tcp dport "$HTTP_PORT" accept 2>/dev/null || true
elif command -v iptables >/dev/null 2>&1; then
  iptables -I INPUT -p tcp --dport "$HTTP_PORT" -j ACCEPT 2>/dev/null || true
fi
if command -v nft >/dev/null 2>&1; then
  nft add rule inet beaut udp dport "$WG_PORT" accept 2>/dev/null || true
elif command -v iptables >/dev/null 2>&1; then
  iptables -I INPUT -p udp --dport "$WG_PORT" -j ACCEPT 2>/dev/null || true
fi
echo "Ports $HTTP_PORT (HTTP) et $WG_PORT (WireGuard) ouverts."
echo

# --- 5. Vérification ---
echo "[5/6] Vérification de l'installation"
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet beaut.service; then
  echo "Le serveur beaut est en ligne sur http://$DOMAIN:$HTTP_PORT"
else
  echo "Le serveur n'a pas pu démarrer automatiquement. Lancez :"
  echo "  $DEPLOY_DIR/scripts/http_server.sh &"
fi
echo

# --- 6. Instructions pour les agents ---
echo "[6/6] Instructions pour les agents"
echo "Sur chaque nœud invité, exécuter (en tant qu'utilisateur non-root) :"
echo "  curl http://$DOMAIN:$HTTP_PORT/install | sh"
echo "Puis rejoindre le WireGuard avec la clé publique ci-dessus."
echo
echo "=== Installation terminée ==="
