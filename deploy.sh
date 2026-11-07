#!/usr/bin/env bash
# deploy.sh — installation du serveur de contrôle beaut.
#
# Avec root : installe WireGuard, service systemd, ouvre les ports.
# Sans root : demande confirmation des ports/dossiers, installe en local
# (scripts + config uniquement, pas de privilèges système).
#
# Usage : ./deploy.sh [--no-root]

set -uo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$DEPLOY_DIR/scripts"

NO_ROOT=0
[[ "${1:-}" == "--no-root" ]] && NO_ROOT=1

# Charge la config (commentée, éditable à la main)
. "$DEPLOY_DIR/config.env" 2>/dev/null || . "$DEPLOY_DIR/config.env.example"
[[ -f "$DEPLOY_DIR/.env" ]] && . "$DEPLOY_DIR/.env"
export NAME DIR STATE_DIR DOMAIN HTTP_PORT WG_PORT WG_NET WG_SERVER_IP \
  LEASE_TTL_SECONDS HEARTBEAT_INTERVAL WORKER_STALE_SECONDS LOG_LEVEL \
  NICE_ROOT NICE_VIP NICE_GUEST

# Source les libs
. "$SCRIPTS_DIR/lib/core.sh"
SCRIPTS_DIR="$DEPLOY_DIR/scripts"

confirm() {
  # Demande confirmation à l'utilisateur (y/N par défaut)
  local prompt="$1"
  local reponse
  read -r -p "$prompt [o/N]: " reponse < /dev/tty 2>/dev/null || read -r -p "$prompt [o/N]: " reponse
  [[ "$reponse" == "o" || "$reponse" == "O" || "$reponse" == "y" || "$reponse" == "Y" ]]
}

if [[ $NO_ROOT -eq 1 ]]; then
  echo "=== Installation beaut en mode non-root ==="
  echo
  echo "Vous n'avez pas les privilèges root. L'installation sera locale."
  echo

  # Demande confirmation des ports
  echo "Configuration réseau :"
  read -r -p "Port HTTP [$HTTP_PORT] : " hp < /dev/tty 2>/dev/null || read -r -p "Port HTTP [$HTTP_PORT] : " hp
  [[ -n "$hp" ]] && HTTP_PORT="$hp"
  read -r -p "Port WireGuard [$WG_PORT] : " wp < /dev/tty 2>/dev/null || read -r -p "Port WireGuard [$WG_PORT] : " wp
  [[ -n "$wp" ]] && WG_PORT="$wp"
  echo

  # Demande confirmation des dossiers
  echo "Répertoires :"
  read -r -p "Répertoire d'état [$STATE_DIR] : " sd < /dev/tty 2>/dev/null || read -r -p "Répertoire d'état [$STATE_DIR] : " sd
  [[ -n "$sd" ]] && STATE_DIR="$sd"
  echo

  export HTTP_PORT WG_PORT STATE_DIR

  echo "[1/4] Création du répertoire d'état ($STATE_DIR)"
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"

  echo "[2/4] Génération des clés WireGuard (clé publique uniquement, pas d'interface)"
  if command -v wg >/dev/null 2>&1; then
    wg genkey | tee "$STATE_DIR/wg_private.key" | wg pubkey > "$STATE_DIR/wg_public.key"
    chmod 600 "$STATE_DIR/wg_private.key"
    echo "Clé publique : $(cat "$STATE_DIR/wg_public.key")"
  else
    echo "ATTENTION: wg non trouvé. Générez les clés manuellement plus tard."
    : > "$STATE_DIR/wg_private.key"
    : > "$STATE_DIR/wg_public.key"
  fi

  echo "[3/4] Installation des scripts et configuration"
  mkdir -p "$STATE_DIR/bin"
  cp -r "$SCRIPTS_DIR"/* "$STATE_DIR/bin/" 2>/dev/null || true
  cp "$DEPLOY_DIR/config.env" "$STATE_DIR/" 2>/dev/null || true

  echo "[4/4] Script de démarrage local ($STATE_DIR/bin/start.sh)"
  cat > "$STATE_DIR/bin/start.sh" <<STARTEOF
#!/usr/bin/env bash
set -uo pipefail
export DOMAIN=$DOMAIN HTTP_PORT=$HTTP_PORT WG_PORT=$WG_PORT
export WG_NET=$WG_NET WG_SERVER_IP=$WG_SERVER_IP
export LEASE_TTL_SECONDS=$LEASE_TTL_SECONDS HEARTBEAT_INTERVAL=$HEARTBEAT_INTERVAL
export WORKER_STALE_SECONDS=$WORKER_STALE_SECONDS LOG_LEVEL=$LOG_LEVEL
export NICE_ROOT=$NICE_ROOT NICE_VIP=$NICE_VIP NICE_GUEST=$NICE_GUEST
export STATE_DIR=$STATE_DIR
cd "$STATE_DIR/bin"
exec bash http_server.sh
STARTEOF
  chmod +x "$STATE_DIR/bin/start.sh"

  echo
  echo "=== Installation non-root terminée ==="
  echo "Pour lancer le serveur : $STATE_DIR/bin/start.sh &"
  echo "Pour installer un agent : curl http://$DOMAIN:$HTTP_PORT/install | sh"
  echo "Le fichier de config est dans : $STATE_DIR/config.env"
  echo

else
  [[ $EUID -eq 0 ]] || { echo "deploy.sh doit être lancé en root (sudo ./deploy.sh) ou avec --no-root" >&2; exit 1; }

  echo "=== Installation du serveur beaut sur $DOMAIN:$HTTP_PORT ==="
  echo

  echo "[1/6] Création du répertoire d'état ($STATE_DIR)"
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"

  echo "[2/6] Configuration de WireGuard"
  bash "$SCRIPTS_DIR/wg_setup.sh"
  echo "Clé publique WireGuard : $(cat "$STATE_DIR/wg_public.key")"
  echo

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
    echo "ATTENTION: systemctl non trouvé. Lancez manuellement : $DEPLOY_DIR/scripts/http_server.sh &"
  fi
  echo

  echo "[4/6] Ouverture du port HTTP ($HTTP_PORT)"
  if command -v nft >/dev/null 2>&1; then
    nft add rule inet beaut tcp dport "$HTTP_PORT" accept 2>/dev/null || true
    nft add rule inet beaut udp dport "$WG_PORT" accept 2>/dev/null || true
  elif command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport "$HTTP_PORT" -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p udp --dport "$WG_PORT" -j ACCEPT 2>/dev/null || true
  fi
  echo "Ports $HTTP_PORT (HTTP) et $WG_PORT (WireGuard) ouverts."
  echo

  echo "[5/6] Vérification de l'installation"
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet beaut.service; then
    echo "Le serveur beaut est en ligne sur http://$DOMAIN:$HTTP_PORT"
  else
    echo "Le serveur n'a pas pu démarrer automatiquement. Lancez :"
    echo "  $DEPLOY_DIR/scripts/http_server.sh &"
  fi
  echo

  echo "[6/6] Instructions pour les agents"
  echo "Sur chaque nœud invité, exécuter (en tant qu'utilisateur non-root) :"
  echo "  curl http://$DOMAIN:$HTTP_PORT/install | sh"
  echo "Puis rejoindre le WireGuard avec la clé publique ci-dessus."
  echo
  echo "=== Installation terminée ==="
fi
