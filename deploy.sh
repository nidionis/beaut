#!/usr/bin/env bash
# deploy.sh — installation de beaut sur l'ordinateur $DOMAIN.
#
# Sans argument : installation distante via SSH/SFTP sur $DOMAIN.
#   --no-root : installation locale (pas de privilèges système).
#
# Cree l'utilisateur sudoer $NAME=beaut, autorise la cle d'installation
# (+ clefs optionnelles depuis config.env), configure WireGuard,
# depose les scripts, lance le serveur HTTP et initialise git.
set -uo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$DEPLOY_DIR/scripts"
FILES_DIR="$DEPLOY_DIR/deploy/files"

NO_ROOT=0
[[ "${1:-}" == "--no-root" ]] && NO_ROOT=1

. "$DEPLOY_DIR/config.env" 2>/dev/null || . "$DEPLOY_DIR/config.env.example"
[[ -f "$DEPLOY_DIR/.env" ]] && . "$DEPLOY_DIR/.env"
export NAME DIR STATE_DIR DOMAIN HTTP_PORT WG_PORT WG_NET WG_SERVER_IP \
  TOKEN_TTL_SECONDS LOG_LEVEL HTTP_FILE_ROOT ERR404 HIST_MEM_MAX_RATIO \
  SUDOER

. "$SCRIPTS_DIR/lib/core.sh"

confirm() {
  local prompt="$1" reponse
  read -r -p "$prompt [o/N]: " reponse < /dev/tty 2>/dev/null || read -r -p "$prompt [o/N]: " reponse
  [[ "$reponse" == "o" || "$reponse" == "O" || "$reponse" == "y" || "$reponse" == "Y" ]]
}

# --- Installation sur une machine distante via SSH/SFTP --------------------
remote_install() {
  [[ -n "$DOMAIN" ]] || { log error "DOMAIN non defini dans config.env"; exit 2; }
  cmd_exists ssh || { log error "ssh requis pour l'installation distante"; exit 2; }
  cmd_exists scp || { log error "scp requis pour l'installation distante"; exit 2; }

  log info "Installation distante sur $DOMAIN (utilisateur $SUDOER)"

  # 1. Creer l'utilisateur sudoer $NAME (si absent) via $SUDOER
  ssh "${SUDOER}@$DOMAIN" "sudo id -u $NAME >/dev/null 2>&1 || (sudo useradd -m -s /bin/bash $NAME && sudo usermod -aG sudo $NAME && echo '$NAME ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/$NAME)" \
    || { log error "impossible de creer l'utilisateur $NAME sur $DOMAIN"; exit 2; }

  # 2. Autoriser la cle d'installation (et clefs optionnelles) pour $NAME
  local auth_keys="$HOME/.ssh/id_ed25519.pub"
  [[ -f "$auth_keys" ]] || auth_keys="$HOME/.ssh/id_rsa.pub"
  if [[ -f "$auth_keys" ]]; then
    ssh "${SUDOER}@$DOMAIN" "sudo -u $NAME bash -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'" < "$auth_keys"
    log info "cle d'installation autorisee pour $NAME sur $DOMAIN"
  fi

  # 3. Copier les scripts et la config vers $NAME
  ssh "${SUDOER}@$DOMAIN" "sudo -u $NAME bash -c 'mkdir -p ~/beaut/scripts ~/beaut/deploy/files ~/beaut/state'" \
    || { log error "impossible de creer l'arborescence sur $DOMAIN"; exit 2; }
  scp -r "$SCRIPTS_DIR"/* "${SUDOER}@$DOMAIN:~/beaut/scripts/"
  scp "$DEPLOY_DIR/config.env" "${SUDOER}@$DOMAIN:~/beaut/"
  scp "$FILES_DIR/start.sh" "${SUDOER}@$DOMAIN:~/beaut/deploy/files/start.sh"
  ssh "${SUDOER}@$DOMAIN" "sudo -u $NAME bash -c 'chmod +x ~/beaut/scripts/*.sh ~/beaut/scripts/lib/*.sh ~/beaut/deploy/files/start.sh'"

  # 4. Git : depot de déploiement
  ssh "${SUDOER}@$DOMAIN" "sudo -u $NAME bash -c 'cd ~/beaut && git init -q 2>/dev/null; git add -A; git commit -q -m \"deploy: installation initiale\" 2>/dev/null || true'"

  # 5. WireGuard + lancement serveur
  ssh "${SUDOER}@$DOMAIN" "sudo -u $NAME bash -c 'cd ~/beaut && export DOMAIN=$DOMAIN HTTP_PORT=$HTTP_PORT WG_PORT=$WG_PORT WG_NET=$WG_NET WG_SERVER_IP=$WG_SERVER_IP TOKEN_TTL_SECONDS=$TOKEN_TTL_SECONDS && bash scripts/wg_setup.sh && nohup bash scripts/http_server.sh > ~/beaut/state/http.log 2>&1 &'"

  log info "Installation terminee sur $DOMAIN"
  log info "Serveur de scripts : http://$DOMAIN:$HTTP_PORT"
  log info "Node : curl http://$DOMAIN:$HTTP_PORT/work | sh"
}

# --- Installation locale (--no-root) ---------------------------------------
local_install() {
  echo "=== Installation beaut (local, sans root) ==="
  local target="${STATE_DIR:-$DIR/state}"
  mkdir -p "$target"
  cp -r "$SCRIPTS_DIR"/* "$target/" 2>/dev/null || true
  cp "$DEPLOY_DIR/config.env" "$target/"
  cp "$FILES_DIR/start.sh" "$target/deploy/files/start.sh"
  chmod +x "$target"/scripts/*.sh "$target"/scripts/lib/*.sh "$target/deploy/files/start.sh"

  echo
  echo "=== Terminé ==="
  echo "Lancer : cd $target && bash deploy/files/start.sh &"
  echo "Node   : curl http://$DOMAIN:$HTTP_PORT/work | sh"
}

if [[ $NO_ROOT -eq 1 ]]; then
  local_install
else
  remote_install
fi
