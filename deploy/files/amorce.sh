#!/usr/bin/env bash
# amorce.sh — première application sur la machine distante, exécutée en root
# (via $SUDOER). Crée $NOM, sa clé, son arborescence, la copie root des scripts
# et le helper sudo limité s$NOM. Rien d'autre : le reste se fait en $NOM.
set -euo pipefail
export LC_ALL=C

: "${NOM:?NOM manquant}"
: "${CLE_B64:?CLE_B64 manquant}"
: "${PAQUET:=/tmp/beaut-amorce.tgz}"
: "${DOMAINE:=192.168.8.240}"
: "${PORT_HTTP:=8080}"
: "${PORT_WG:=51820}"
: "${RESEAU_WG:=10.66.0.0/24}"
: "${IP_SRV_WG:=10.66.0.1}"
: "${TTL_TOKEN:=300}"

RACINE=/usr/local/lib/beaut
BIN=/usr/local/sbin
CIBLE=/home/$NOM

dire() { printf '[amorce] %s\n' "$*" >&2; }
mourir() { dire "erreur: $*"; exit 1; }

[[ "$(id -u)" -eq 0 ]] || mourir "amorce.sh doit tourner en root (utiliser SUDOER=root)"
[[ -f "$PAQUET" ]] || mourir "paquet introuvable: $PAQUET"

# nettoyage garanti (paquet + dossier temporaire)
TMP=""
nettoyer_paquet() {
  if [[ -n "$TMP" ]]; then rm -rf -- "$TMP"; fi
  rm -f -- "$PAQUET"
}
trap nettoyer_paquet EXIT

# 1. utilisateur $NOM (créé si absent), home standardisé
if id -u "$NOM" >/dev/null 2>&1; then
  MAISON="$(getent passwd "$NOM" | cut -d: -f6)"
else
  useradd -m -s /bin/bash "$NOM"
  MAISON="$(getent passwd "$NOM" | cut -d: -f6)"
fi
[[ -n "$MAISON" ]] || mourir "home de $NOM introuvable"
GROUPE="$(id -gn "$NOM")"

if [[ "$MAISON" != "$CIBLE" ]]; then
  # ne supprimer que les restes vides laissés par les essais précédents
  if [[ -d "$MAISON" ]] && [[ -z "$(find "$MAISON" -mindepth 1 -maxdepth 1 -printf '%f\n' | grep -vxF "$NOM" || true)" ]]; then
    rm -rf -- "${MAISON:?}/$NOM"
  fi
  if [[ -d "$MAISON" ]] && [[ -z "$(find "$CIBLE" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    usermod -d "$CIBLE" -m "$NOM" 2>/dev/null || usermod -d "$CIBLE" "$NOM"
  else
    usermod -d "$CIBLE" "$NOM"
  fi
  MAISON="$CIBLE"
fi
install -d -o "$NOM" -g "$GROUPE" "$MAISON"
chmod go-w "$MAISON"

# 2. clé publique -> authorized_keys (idempotent, droits stricts)
install -d -m 700 -o "$NOM" -g "$GROUPE" "$MAISON/.ssh"
AUTORISEES="$MAISON/.ssh/authorized_keys"
touch "$AUTORISEES"
CLE="$(printf '%s' "$CLE_B64" | base64 -d)"
grep -qxF -- "$CLE" "$AUTORISEES" || printf '%s\n' "$CLE" >> "$AUTORISEES"
chown -R "$NOM:$GROUPE" "$MAISON/.ssh"
chmod 700 "$MAISON/.ssh"
chmod 600 "$AUTORISEES"

# 3. arborescence unique : $HOME/.beaut (scripts, deploy, state, shared)
for d in "$MAISON/.beaut" "$MAISON/.beaut/state" "$MAISON/.beaut/shared"; do
  install -d -m 755 -o "$NOM" -g "$GROUPE" "$d"
done
chmod 700 "$MAISON/.beaut/state"

# 4. copie root:root des scripts + configuration réseau figée (jamais modifiable
#    par $NOM : sinon sudo sur du code utilisateur = escalade de privilèges)
TMP="$(mktemp -d)"
tar xzf "$PAQUET" -C "$TMP"
install -d -m 755 -o root -g root "$RACINE"
rm -rf -- "$RACINE/scripts"
cp -a "$TMP/scripts" "$RACINE/scripts"
cat > "$RACINE/config.env" <<EOF
NAME=$NOM
DIR=/var/lib/beaut
STATE_DIR=/var/lib/beaut/state
DOMAIN=$DOMAINE
HTTP_PORT=$PORT_HTTP
WG_PORT=$PORT_WG
WG_NET=$RESEAU_WG
WG_SERVER_IP=$IP_SRV_WG
TOKEN_TTL_SECONDS=$TTL_TOKEN
LOG_LEVEL=info
EOF
chown -R root:root "$RACINE"
chmod -R go-w "$RACINE"
find "$RACINE/scripts" -type f -name '*.sh' -exec chmod 755 {} +

# 5. helper s$NOM (root:root) + sudo limité à cette seule commande
install -m 755 -o root -g root "$TMP/deploy/files/sbeaut" "$BIN/s$NOM"
printf '%s ALL=(root) NOPASSWD: %s/s%s\n' "$NOM" "$BIN" "$NOM" > "/etc/sudoers.d/$NOM"
chmod 440 "/etc/sudoers.d/$NOM"
if command -v visudo >/dev/null 2>&1; then
  visudo -cf "/etc/sudoers.d/$NOM" >/dev/null
fi

# 6. service utilisateur au démarrage (sans sudo)
if command -v loginctl >/dev/null 2>&1; then
  loginctl enable-linger "$NOM" 2>/dev/null || true
fi

dire "terminé: $NOM (home $MAISON, sudo NOPASSWD $BIN/s$NOM)"
