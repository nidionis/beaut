#!/usr/bin/env bash
# deploy.sh — amorçage de beaut sur la machine $DOMAIN.
#
#   ./deploy.sh              installation distante (SSH/SFTP)
#   ./deploy.sh --no-root    installation locale, sans privilèges
#
# Deux temps, une seule bascule d'identité :
#   1. $SUDOER (root conseillé) applique deploy/files/amorce.sh : crée $NAME,
#      autorise la clé, installe la copie root des scripts + le helper s$NAME.
#   2. tout le reste se fait en $NAME (clé privée, sans mot de passe), dans
#      $HOME/.beaut : scripts, deploy, state, shared (arborescence HTTP).
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$DEPLOY_DIR/scripts"
FILES_DIR="$DEPLOY_DIR/deploy/files"

NO_ROOT=0
[[ "${1:-}" == "--no-root" ]] && NO_ROOT=1

CONFIG="$DEPLOY_DIR/config.env"
[[ -f "$CONFIG" ]] || CONFIG="$DEPLOY_DIR/config.env.example"
set -a; . "$CONFIG"; set +a
if [[ -f "$DEPLOY_DIR/.env" ]]; then set -a; . "$DEPLOY_DIR/.env"; set +a; fi

# replis identiques à lib/core.sh (config facultative)
NAME="${NAME:-beaut}"
DIR="${DIR:-$HOME/.$NAME}"
STATE_DIR="${STATE_DIR:-$DIR/state}"
DOMAIN="${DOMAIN:-192.168.8.240}"
HTTP_PORT="${HTTP_PORT:-8080}"
WG_PORT="${WG_PORT:-51820}"
WG_NET="${WG_NET:-10.66.0.0/24}"
WG_SERVER_IP="${WG_SERVER_IP:-10.66.0.1}"
TOKEN_TTL_SECONDS="${TOKEN_TTL_SECONDS:-300}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"

. "$SCRIPTS_DIR/lib/core.sh"

mourir() { log error "$*"; exit 1; }

# --- paquet d'amorçage (nettoyé en sortie) ----------------------------------
PAQUET_TMP=""
nettoyer() { if [[ -n "$PAQUET_TMP" ]]; then rm -f -- "$PAQUET_TMP"; fi; }
trap nettoyer EXIT

# --- identité ---------------------------------------------------------------
choisir_sudoer() {
  local defaut="${SUDOER:-root}" reponse=""
  if [[ -t 0 ]]; then
    read -r -p "Sudoer pour la première connexion [$defaut] : " reponse < /dev/tty || true
  fi
  SUDOER="${reponse:-$defaut}"
  [[ -n "$SUDOER" ]] || mourir "SUDOER vide"
}

# --- connexion en tant que $NAME (clé uniquement, jamais de mot de passe) ----
SSH_OPTS=(-o BatchMode=yes -o IdentitiesOnly=yes
          -o PreferredAuthentications=publickey -o StrictHostKeyChecking=accept-new)
en_nom() { ssh -n -i "$SSH_KEY" "${SSH_OPTS[@]}" "$NAME@$DOMAIN" "$@"; }
copier() { scp -i "$SSH_KEY" "${SSH_OPTS[@]}" "$@"; }

# --- 1. amorçage via $SUDOER ------------------------------------------------
amorcer() {
  local cle_b64 prefixe uid_distant distant
  [[ -f "$SSH_KEY" ]]     || mourir "clé privée introuvable : $SSH_KEY"
  [[ -f "$SSH_KEY.pub" ]] || mourir "clé publique introuvable : $SSH_KEY.pub"

  cle_b64="$(base64 -w0 < "$SSH_KEY.pub")"
  distant="/tmp/beaut-amorce.$$.tgz"
  PAQUET_TMP="$(mktemp "${TMPDIR:-/tmp}/beaut.XXXXXX.tgz")"
  tar -czf "$PAQUET_TMP" -C "$DEPLOY_DIR" scripts deploy

  scp "$PAQUET_TMP" "$SUDOER@$DOMAIN:$distant" \
    || mourir "envoi du paquet impossible (SUDOER=$SUDOER)"

  uid_distant="$(ssh "$SUDOER@$DOMAIN" 'id -u')" \
    || mourir "connexion à $SUDOER@$DOMAIN impossible"
  uid_distant="${uid_distant//[[:space:]]/}"
  if [[ "$uid_distant" == "0" ]]; then
    prefixe=""
  else
    ssh "$SUDOER@$DOMAIN" 'sudo -n true' >/dev/null 2>&1 \
      || mourir "$SUDOER n'a pas de sudo sans mot de passe : utiliser SUDOER=root"
    prefixe="sudo -n env"
  fi

  ssh "$SUDOER@$DOMAIN" \
    "$prefixe NOM=$(printf '%q' "$NAME") CLE_B64=$cle_b64 PAQUET=$(printf '%q' "$distant") DOMAINE=$(printf '%q' "$DOMAIN") PORT_HTTP=$(printf '%q' "$HTTP_PORT") PORT_WG=$(printf '%q' "$WG_PORT") RESEAU_WG=$(printf '%q' "$WG_NET") IP_SRV_WG=$(printf '%q' "$WG_SERVER_IP") TTL_TOKEN=$(printf '%q' "$TOKEN_TTL_SECONDS") bash -s" \
    < "$FILES_DIR/amorce.sh" || mourir "amorçage impossible sur $DOMAIN"

  rm -f -- "$PAQUET_TMP"; PAQUET_TMP=""
}

# --- 2. contrôle de la connexion sans mot de passe --------------------------
verifier_cle() {
  en_nom true || mourir "clé refusée pour $NAME@$DOMAIN (authorized_keys, droits du home, StrictModes ?)"
}

# --- 3. dépôt puis étapes en $NAME ------------------------------------------
deposer() {
  copier -r "$SCRIPTS_DIR" "$DEPLOY_DIR/deploy" "$NAME@$DOMAIN:.beaut/" \
    || mourir "copie des scripts impossible"
  copier "$CONFIG" "$NAME@$DOMAIN:.beaut/config.env" \
    || mourir "copie de la configuration impossible"
  en_nom "find ~/.beaut -type f \( -name '*.sh' -o -name 'sbeaut' \) -exec chmod 755 {} +" \
    || mourir "chmod distant impossible"
}

versionner() {
  en_nom 'cd ~/.beaut && if command -v git >/dev/null 2>&1; then
            git init -q
            git add -A
            git commit -qm "deploy: installation" >/dev/null 2>&1 || true
          else
            echo "git absent: dépôt non initialisé" >&2
          fi' || true
}

# --- 4. arborescence HTTP : le path reflète le fichier ----------------------
publier() {
  en_nom 'set -e
    cd ~/.beaut
    mkdir -p shared
    rm -rf shared/scripts shared/deploy
    cp -a scripts shared/scripts
    cp -a deploy shared/deploy
    mkdir -p shared/node
    cp -f scripts/http_exec.sh shared/node/DEFAULT.sh
    cp -f scripts/wg_join.sh shared/join
    chmod -R a+rX shared' || mourir "publication de l'arborescence impossible"
}

# --- 5. ressources spéciales via sudo limité (s$NAME) -----------------------
reseau() {
  en_nom "if command -v wg >/dev/null 2>&1; then
            sudo -n s$NAME || echo 'avertissement: réseau non configuré' >&2
          else
            echo 'avertissement: wireguard absent, réseau ignoré' >&2
          fi" || true
}

# --- 6. service utilisateur (setsid en secours) -----------------------------
demarrer() {
  en_nom 'set -e
    mkdir -p ~/.config/systemd/user
    cp -f ~/.beaut/deploy/files/beaut.service ~/.config/systemd/user/beaut.service
    if command -v systemctl >/dev/null 2>&1 \
       && systemctl --user daemon-reload 2>/dev/null \
       && systemctl --user enable --now beaut.service 2>/dev/null; then
      echo "service utilisateur beaut actif"
    else
      pkill -f "beaut/scripts/http_server.sh" 2>/dev/null || true
      setsid bash ~/.beaut/deploy/files/start.sh \
        > ~/.beaut/state/http.log 2>&1 < /dev/null &
      echo "serveur lancé via setsid (voir state/http.log)"
    fi' || mourir "démarrage du serveur impossible"
}

attendre_serveur() {
  local essai
  for essai in 1 2 3 4 5; do
    curl -fsS "http://$DOMAIN:$HTTP_PORT/work" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

installer_distance() {
  cmd_exists ssh  || mourir "ssh requis"
  cmd_exists scp  || mourir "scp requis"
  cmd_exists curl || mourir "curl requis"

  choisir_sudoer
  log info "amorçage de $DOMAIN via $SUDOER, puis $NAME"
  amorcer
  verifier_cle
  log info "clé acceptée pour $NAME@$DOMAIN"

  deposer
  versionner
  publier
  reseau
  demarrer

  if attendre_serveur; then
    log info "serveur actif : http://$DOMAIN:$HTTP_PORT"
    log info "node : curl -fsS http://$DOMAIN:$HTTP_PORT/node | sh"
  else
    log error "serveur non joignable sur http://$DOMAIN:$HTTP_PORT (~/.beaut/state/http.log)"
    exit 1
  fi
  log info "installation terminée sur $DOMAIN (utilisateur $NAME)"
}

# --- mode local -------------------------------------------------------------
installer_local() {
  local cible="${DIR:-$HOME/.$NAME}"
  mkdir -p "$cible/state" "$cible/shared" "$cible/deploy"
  cp -a "$SCRIPTS_DIR" "$cible/"
  cp -a "$FILES_DIR" "$cible/deploy/"
  cp -f "$CONFIG" "$cible/config.env"
  find "$cible/scripts" -type f -name '*.sh' -exec chmod 755 {} +
  chmod 755 "$cible/deploy/files/start.sh"
  echo "=== installation locale terminée dans $cible ==="
  echo "lancer : bash $cible/deploy/files/start.sh"
}

if [[ $NO_ROOT -eq 1 ]]; then
  installer_local
else
  installer_distance
fi
