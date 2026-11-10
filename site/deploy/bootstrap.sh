#!/usr/bin/env bash
# bootstrap.sh — first application on the remote host, run as root through
# BOOTSTRAP_USER. Creates SERVICE_USER, its SSH key, its tree, the root-owned
# copy of the scripts, and the passwordless sudo grant for SERVICE_USER.
# Nothing else: the rest of the deployment runs as SERVICE_USER.
set -euo pipefail
export LC_ALL=C

: "${SERVICE_USER:?missing SERVICE_USER}"
: "${PUBLIC_KEY_B64:?missing PUBLIC_KEY_B64}"
: "${PAYLOAD_ARCHIVE:=/tmp/beaut-bootstrap.tgz}"

ROOT_LIB_DIR=/usr/local/lib/beaut
TARGET_HOME=/home/$SERVICE_USER

note() { printf '[bootstrap] %s\n' "$*" >&2; }
die() { note "error: $*"; exit 1; }

[[ "$SERVICE_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid SERVICE_USER: $SERVICE_USER"
[[ "$(id -u)" -eq 0 ]] || die "bootstrap.sh must run as root (use BOOTSTRAP_USER=root)"
[[ -f "$PAYLOAD_ARCHIVE" ]] || die "payload not found: $PAYLOAD_ARCHIVE"

WORK_DIR=""
cleanup_payload() {
  if [[ -n "$WORK_DIR" ]]; then rm -rf -- "$WORK_DIR"; fi
  rm -f -- "$PAYLOAD_ARCHIVE"
}
trap cleanup_payload EXIT

# 1. service user (created if missing), login shell and home standardized.
#    An account may already exist with /usr/sbin/nologin: key auth would succeed
#    but every session would die with "This account is currently not available."
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$SERVICE_USER"
fi
IFS=: read -r _ _ _ _ _ home_dir login_shell _ < <(getent passwd "$SERVICE_USER")
[[ -n "$home_dir" ]] || die "home directory not found for $SERVICE_USER"
[[ "$login_shell" == "/bin/bash" ]] || usermod -s /bin/bash "$SERVICE_USER"
primary_group="$(id -gn "$SERVICE_USER")"

if [[ "$home_dir" != "$TARGET_HOME" ]]; then
  # remove only the empty leftovers of previous failed runs
  if [[ -d "$home_dir" ]] && [[ -z "$(find "$home_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | grep -vxF "$SERVICE_USER" || true)" ]]; then
    rm -rf -- "${home_dir:?}/$SERVICE_USER"
  fi
  if [[ -d "$home_dir" ]] && [[ -z "$(find "$TARGET_HOME" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    usermod -d "$TARGET_HOME" -m "$SERVICE_USER" 2>/dev/null || usermod -d "$TARGET_HOME" "$SERVICE_USER"
  else
    usermod -d "$TARGET_HOME" "$SERVICE_USER"
  fi
  home_dir="$TARGET_HOME"
fi
install -d -o "$SERVICE_USER" -g "$primary_group" "$home_dir"
chmod go-w "$home_dir"

# 2. public key -> authorized_keys (idempotent, strict permissions)
install -d -m 700 -o "$SERVICE_USER" -g "$primary_group" "$home_dir/.ssh"
authorized_keys_file="$home_dir/.ssh/authorized_keys"
touch "$authorized_keys_file"
public_key="$(printf '%s' "$PUBLIC_KEY_B64" | base64 -d)"
grep -qxF -- "$public_key" "$authorized_keys_file" || printf '%s\n' "$public_key" >> "$authorized_keys_file"
chown -R "$SERVICE_USER:$primary_group" "$home_dir/.ssh"
chmod 700 "$home_dir/.ssh"
chmod 600 "$authorized_keys_file"

# 3. single tree: $HOME/.beaut (site, state)
for directory in "$home_dir/.beaut" "$home_dir/.beaut/state" "$home_dir/.beaut/site"; do
  install -d -m 755 -o "$SERVICE_USER" -g "$primary_group" "$directory"
done
chmod 700 "$home_dir/.beaut/state"

# 4. root-owned copy of the scripts + frozen network config. Never writable by
#    the service user: it runs through the sudo grant below. The same installer
#    refreshes it on later deploys.
WORK_DIR="$(mktemp -d)"
tar xzf "$PAYLOAD_ARCHIVE" -C "$WORK_DIR"
SOURCE_DIRECTORY="$WORK_DIR" SERVICE_ROOT="$TARGET_HOME/.beaut" \
  STATE_DIR="$TARGET_HOME/.beaut/state" PUBLISHED_ROOT="$TARGET_HOME/.beaut/site" \
  ROOT_LIBRARY_DIRECTORY="$ROOT_LIB_DIR" \
  bash "$WORK_DIR/site/deploy/install_privileged.sh"

# 5. sudo grant for the service user (full, passwordless; validated with visudo)
install -d -m 755 /etc/sudoers.d
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$SERVICE_USER" > "/etc/sudoers.d/$SERVICE_USER"
chmod 440 "/etc/sudoers.d/$SERVICE_USER"
if command -v visudo >/dev/null 2>&1; then
  visudo -cf "/etc/sudoers.d/$SERVICE_USER" >/dev/null
fi

# 6. start the user service at boot (no sudo)
if command -v loginctl >/dev/null 2>&1; then
  loginctl enable-linger "$SERVICE_USER" 2>/dev/null || true
fi

note "done: $SERVICE_USER (home $home_dir, sudo NOPASSWD /etc/sudoers.d/$SERVICE_USER)"
