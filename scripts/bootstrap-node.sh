#!/usr/bin/env bash
# bootstrap-node.sh - prepare a node for beaut installation.
#
# Run once on a new hub or worker:
#
#   sudo ./scripts/bootstrap-node.sh
#
# It creates the BEAUT_NAME account, gives it a login shell, authorizes the
# invoking user's SSH keys, grants passwordless sudo and adds it to the docker
# group.  Everything else (files, config, units) is installed by
# `./beaut.sh install hub|worker NAME|all` over SSH as BEAUT_NAME.
set -euo pipefail

BEAUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export BEAUT_ROOT

# shellcheck disable=SC1091
. "$BEAUT_ROOT/etc/beaut.defaults.conf"
if [[ -f "${BEAUT_CONFIG:-$BEAUT_ROOT/beaut.conf}" ]]; then
  # shellcheck disable=SC1090
  . "${BEAUT_CONFIG:-$BEAUT_ROOT/beaut.conf}"
fi

: "${BEAUT_NAME:=beaut}"
: "${BEAUT_USER:=$BEAUT_NAME}"
: "${BEAUT_GROUP:=$BEAUT_USER}"
: "${BEAUT_HOME:=/var/lib/$BEAUT_NAME}"

log() { printf '[beaut-bootstrap] %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "run with sudo"
getent passwd "$BEAUT_USER" >/dev/null 2>&1 || [[ ! -e "$BEAUT_HOME" ]] \
  || die "$BEAUT_HOME exists but $BEAUT_USER does not"

SOURCE_USER="${SUDO_USER:-root}"
SOURCE_HOME="$(getent passwd "$SOURCE_USER" | cut -d: -f6)"
[[ -n "$SOURCE_HOME" ]] || die "cannot find the home directory of $SOURCE_USER"

KEY_FILE="$(mktemp "${TMPDIR:-/tmp}/beaut-keys.XXXXXX")"
trap 'rm -f -- "$KEY_FILE"' EXIT
for pub in "$SOURCE_HOME"/.ssh/*.pub; do
  [[ -r "$pub" ]] && cat -- "$pub" >> "$KEY_FILE"
done
if [[ ! -s "$KEY_FILE" && -r "$SOURCE_HOME/.ssh/authorized_keys" ]]; then
  cat -- "$SOURCE_HOME/.ssh/authorized_keys" >> "$KEY_FILE"
fi
[[ -s "$KEY_FILE" ]] || die "no SSH public keys found for $SOURCE_USER"

if ! getent group "$BEAUT_GROUP" >/dev/null 2>&1; then
  groupadd --system "$BEAUT_GROUP"
fi
if getent passwd "$BEAUT_USER" >/dev/null 2>&1; then
  usermod -d "$BEAUT_HOME" -s /bin/bash -g "$BEAUT_GROUP" "$BEAUT_USER"
else
  useradd -m -d "$BEAUT_HOME" -s /bin/bash -g "$BEAUT_GROUP" "$BEAUT_USER"
fi
install -d -m 755 -o "$BEAUT_USER" -g "$BEAUT_GROUP" "$BEAUT_HOME"
install -d -m 700 -o "$BEAUT_USER" -g "$BEAUT_GROUP" "$BEAUT_HOME/.ssh"

TARGET_KEYS="$BEAUT_HOME/.ssh/authorized_keys"
touch "$TARGET_KEYS"
if [[ -s "$TARGET_KEYS" ]] && [[ -n "$(tail -c 1 "$TARGET_KEYS")" ]]; then
  printf '\n' >> "$TARGET_KEYS"
fi
added=0
while IFS= read -r key; do
  [[ -n "$key" && "$key" != \#* ]] || continue
  grep -qxF -- "$key" "$TARGET_KEYS" && continue
  printf '%s\n' "$key" >> "$TARGET_KEYS"
  added=$((added + 1))
done < "$KEY_FILE"
chown -R "$BEAUT_USER:$BEAUT_GROUP" "$BEAUT_HOME/.ssh"
chmod 700 "$BEAUT_HOME/.ssh"
chmod 600 "$TARGET_KEYS"

SUDOERS="/etc/sudoers.d/$BEAUT_NAME"
install -d -m 755 /etc/sudoers.d
cat > "$SUDOERS" <<EOF
Defaults:$BEAUT_USER !requiretty
$BEAUT_USER ALL=(ALL:ALL) NOPASSWD: ALL
EOF
chmod 440 "$SUDOERS"
if command -v visudo >/dev/null 2>&1; then
  visudo -cf "$SUDOERS" >/dev/null || {
    rm -f -- "$SUDOERS"
    die "invalid sudoers entry"
  }
fi

if getent group docker >/dev/null 2>&1; then
  usermod -aG docker "$BEAUT_USER"
fi

log "user $BEAUT_USER ready (home $BEAUT_HOME, shell /bin/bash)"
log "authorized $added key(s) from $SOURCE_USER"
log "next: ./beaut.sh install hub|worker NAME|all"
