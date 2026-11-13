#!/usr/bin/env bash
# install.sh - privileged installer run on a hub/worker.
#
# `beaut install` (lib/deploy.sh) invokes this script locally for this machine,
# or uploads the source tree over SFTP and invokes it through SSH for a remote
# node.  The caller provides BEAUT_INSTALL_* variables.  Authentication for
# remote access is key/agent only; this installer never creates or manages
# service-account passwords.
set -euo pipefail

[[ "$(id -u)" == "0" ]] || {
  printf 'install.sh must run as root\n' >&2
  exit 1
}

: "${BEAUT_INSTALL_SRC:?missing BEAUT_INSTALL_SRC}"
: "${BEAUT_INSTALL_CONFIG:?missing BEAUT_INSTALL_CONFIG}"
: "${BEAUT_INSTALL_ROLE:?missing BEAUT_INSTALL_ROLE}"

BEAUT_ROOT="${BEAUT_ROOT:-$BEAUT_INSTALL_SRC}"
export BEAUT_ROOT

# The uploaded tree carries the protected defaults, so the installer and the
# installed runtime use the same identity, paths and limits.
if [[ -f "$BEAUT_INSTALL_SRC/etc/beaut.defaults.conf" ]]; then
  # shellcheck disable=SC1090
  . "$BEAUT_INSTALL_SRC/etc/beaut.defaults.conf"
fi

: "${BEAUT_NAME:=beaut}"
: "${BEAUT_INSTALL_NAME:=$BEAUT_NAME}"
: "${BEAUT_INSTALL_HOST:=unknown}"
: "${BEAUT_USER:=$BEAUT_NAME}"
: "${BEAUT_GROUP:=$BEAUT_USER}"
# Deployment-specific BEAUT_INSTALL_* values take precedence over the protected
# defaults so a remote install can use a non-standard layout.
BEAUT_HOME="${BEAUT_INSTALL_HOME:-${BEAUT_HOME:-/var/lib/$BEAUT_NAME}}"
BEAUT_CONFIG_DIR="${BEAUT_INSTALL_CONFIG_DIR:-${BEAUT_CONFIG_DIR:-/etc/$BEAUT_NAME}}"
BEAUT_STATE_DIR="${BEAUT_INSTALL_STATE_DIR:-$BEAUT_HOME/state}"
BEAUT_STORE_DIR="${BEAUT_INSTALL_STORE_DIR:-$BEAUT_HOME/store}"
BEAUT_LOG_DIR="${BEAUT_INSTALL_LOG_DIR:-/var/log/$BEAUT_NAME}"
BEAUT_INSTALL_DEST="${BEAUT_INSTALL_DEST:-/usr/local/lib/$BEAUT_NAME}"
BEAUT_BIN="${BEAUT_INSTALL_BIN:-/usr/local/bin/$BEAUT_NAME}"
BEAUT_INSTALL_DEPS="${BEAUT_INSTALL_DEPS:-1}"
BEAUT_INSTALL_DOCKER="${BEAUT_INSTALL_DOCKER:-0}"
BEAUT_ENABLE_ROUTER="${BEAUT_ENABLE_ROUTER:-1}"

log() { printf '[%s-install] %s\n' "$BEAUT_NAME" "$*" >&2; }
warn() { printf '[%s-install] warning: %s\n' "$BEAUT_NAME" "$*" >&2; }

install_packages() {
  [[ "$BEAUT_INSTALL_DEPS" == "1" ]] || return 0
  local missing=0
  local command
  for command in socat jq curl tar gzip; do
    command -v "$command" >/dev/null 2>&1 || missing=1
  done
  (( missing == 1 )) || return 0
  log "installing basic dependencies"
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y socat jq curl tar gzip >/dev/null || warn "dnf dependency install failed"
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq >/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y socat jq curl tar gzip >/dev/null \
      || warn "apt dependency install failed"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache socat jq curl tar gzip >/dev/null || warn "apk dependency install failed"
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm socat jq curl tar gzip >/dev/null || warn "pacman dependency install failed"
  else
    warn "no supported package manager; install socat jq curl tar gzip manually"
  fi
}

install_docker() {
  [[ "$BEAUT_INSTALL_DOCKER" == "1" ]] || return 0
  command -v docker >/dev/null 2>&1 && return 0
  log "installing Docker"
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y docker >/dev/null || warn "dnf docker install failed"
  elif command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io >/dev/null \
      || warn "apt docker install failed"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache docker >/dev/null || warn "apk docker install failed"
  elif command -v pacman >/dev/null 2>&1; then
    pacman -S --noconfirm docker >/dev/null || warn "pacman docker install failed"
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
}

create_identity() {
  # scripts/bootstrap-node.sh owns the service account, SSH keys and sudo
  # grant.  The installer only needs the account to exist.
  getent passwd "$BEAUT_USER" >/dev/null 2>&1 || {
    warn "$BEAUT_USER does not exist; run scripts/bootstrap-node.sh with sudo first"
    exit 1
  }
  if getent group docker >/dev/null 2>&1; then
    usermod -aG docker "$BEAUT_USER" >/dev/null 2>&1 || true
  fi
}

install_files() {
  install -d -m 755 "$BEAUT_INSTALL_DEST"
  local item
  for item in beaut.sh beaut.conf.example lib server www scripts deploy etc; do
    [[ -e "$BEAUT_INSTALL_SRC/$item" ]] || continue
    rm -rf -- "${BEAUT_INSTALL_DEST:?}/$item"
    cp -a -- "$BEAUT_INSTALL_SRC/$item" "$BEAUT_INSTALL_DEST/$item"
  done
  chown -R root:root "$BEAUT_INSTALL_DEST"
  chmod +x "$BEAUT_INSTALL_DEST/beaut.sh" "$BEAUT_INSTALL_DEST"/server/*.sh \
    "$BEAUT_INSTALL_DEST"/scripts/*.sh 2>/dev/null || true
  install -d -m 755 "$(dirname "$BEAUT_BIN")"
  ln -sfn "$BEAUT_INSTALL_DEST/beaut.sh" "$BEAUT_BIN"
}

install_config() {
  install -d -m 755 "$BEAUT_CONFIG_DIR"
  if [[ -f "$BEAUT_CONFIG_DIR/beaut.conf" ]]; then
    cp -a "$BEAUT_CONFIG_DIR/beaut.conf" \
      "$BEAUT_CONFIG_DIR/beaut.conf.bak.$(date +%s)"
  fi
  install -m 600 -o "$BEAUT_USER" -g "$BEAUT_GROUP" "$BEAUT_INSTALL_CONFIG" \
    "$BEAUT_CONFIG_DIR/beaut.conf"
  # Reinstalling should not accumulate duplicate path blocks.
  if grep -Fq '# installed paths (appended by beaut install.sh)' \
      "$BEAUT_CONFIG_DIR/beaut.conf"; then
    sed -i '/^# installed paths (appended by beaut install.sh)$/,$d' \
      "$BEAUT_CONFIG_DIR/beaut.conf"
  fi
  {
    printf '\n# installed paths (appended by beaut install.sh)\n'
    printf 'BEAUT_ROOT=%q\n' "$BEAUT_INSTALL_DEST"
    printf 'BEAUT_HOME=%q\n' "$BEAUT_HOME"
    printf 'BEAUT_STATE_DIR=%q\n' "$BEAUT_STATE_DIR"
    printf 'BEAUT_STORE_DIR=%q\n' "$BEAUT_STORE_DIR"
    printf 'BEAUT_LOG_DIR=%q\n' "$BEAUT_LOG_DIR"
    printf 'BEAUT_WWW_DIR=%q\n' "$BEAUT_INSTALL_DEST/www"
    printf 'BEAUT_INSTALL_ROLE=%q\n' "$BEAUT_INSTALL_ROLE"
  } >> "$BEAUT_CONFIG_DIR/beaut.conf"
  chown "$BEAUT_USER:$BEAUT_GROUP" "$BEAUT_CONFIG_DIR/beaut.conf"
  chmod 600 "$BEAUT_CONFIG_DIR/beaut.conf"
}

install_dirs() {
  install -d -m 755 -o "$BEAUT_USER" -g "$BEAUT_GROUP" "$BEAUT_HOME"
  install -d -m 700 -o "$BEAUT_USER" -g "$BEAUT_GROUP" \
    "$BEAUT_STATE_DIR" "$BEAUT_STORE_DIR" "$BEAUT_STATE_DIR/sessions" \
    "$BEAUT_STATE_DIR/run"
  install -d -m 750 -o "$BEAUT_USER" -g "$BEAUT_GROUP" "$BEAUT_LOG_DIR"
}

install_units() {
  local template unit content
  for template in beaut-hub.service beaut-worker.service beaut-router.service; do
    [[ -f "$BEAUT_INSTALL_SRC/deploy/$template" ]] || continue
    unit="${BEAUT_NAME}-${template#beaut-}"
    content="$(<"$BEAUT_INSTALL_SRC/deploy/$template")"
    content="${content//beaut-hub.service/${BEAUT_NAME}-hub.service}"
    content="${content//@BEAUT_NAME@/$BEAUT_NAME}"
    content="${content//@BEAUT_USER@/$BEAUT_USER}"
    content="${content//@BEAUT_GROUP@/$BEAUT_GROUP}"
    content="${content//@BEAUT_BIN@/$BEAUT_BIN}"
    content="${content//@BEAUT_CONFIG@/$BEAUT_CONFIG_DIR/beaut.conf}"
    printf '%s\n' "$content" > "/etc/systemd/system/$unit"
    chmod 644 "/etc/systemd/system/$unit"
  done
}

wait_active() {
  local unit="$1" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    systemctl is-active --quiet "$unit" && return 0
    sleep 1
  done
  warn "$unit is not active"
  journalctl -u "$unit" -n 20 --no-pager >&2 || true
  return 1
}

start_services() {
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl daemon-reload
    if [[ "$BEAUT_INSTALL_ROLE" == "hub" ]]; then
      systemctl enable "${BEAUT_NAME}-hub.service" >/dev/null 2>&1 || true
      if ! systemctl restart "${BEAUT_NAME}-hub.service"; then
        warn "hub service failed to start"
        return 1
      fi
      wait_active "${BEAUT_NAME}-hub.service" || return 1
      if [[ "$BEAUT_ENABLE_ROUTER" == "1" ]]; then
        systemctl enable "${BEAUT_NAME}-router.service" >/dev/null 2>&1 || true
        systemctl restart "${BEAUT_NAME}-router.service" || warn "router service failed to start"
      else
        systemctl disable --now "${BEAUT_NAME}-router.service" >/dev/null 2>&1 || true
      fi
    else
      systemctl enable "${BEAUT_NAME}-worker.service" >/dev/null 2>&1 || true
      if ! systemctl restart "${BEAUT_NAME}-worker.service"; then
        warn "worker service failed to start"
        return 1
      fi
      wait_active "${BEAUT_NAME}-worker.service" || return 1
    fi
    return
  fi

  local cmd shell_cmd
  if [[ "$BEAUT_INSTALL_ROLE" == "hub" ]]; then
    cmd="hub serve"
  else
    cmd="worker serve"
  fi
  log "systemd unavailable; starting $BEAUT_INSTALL_ROLE with setsid"
  shell_cmd="BEAUT_CONFIG='$BEAUT_CONFIG_DIR/beaut.conf' setsid '$BEAUT_BIN' $cmd >>'$BEAUT_LOG_DIR/beaut.log' 2>&1 < /dev/null &"
  if command -v runuser >/dev/null 2>&1; then
    runuser -u "$BEAUT_USER" -- bash -c "$shell_cmd" || warn "background start failed"
  else
    su -s /bin/bash -c "$shell_cmd" "$BEAUT_USER" || warn "background start failed"
  fi
  if [[ "$BEAUT_INSTALL_ROLE" == "hub" && "$BEAUT_ENABLE_ROUTER" == "1" ]]; then
    shell_cmd="BEAUT_CONFIG='$BEAUT_CONFIG_DIR/beaut.conf' setsid '$BEAUT_BIN' router run >>'$BEAUT_LOG_DIR/router.log' 2>&1 < /dev/null &"
    if command -v runuser >/dev/null 2>&1; then
      runuser -u "$BEAUT_USER" -- bash -c "$shell_cmd" || true
    else
      su -s /bin/bash -c "$shell_cmd" "$BEAUT_USER" || true
    fi
  fi
}

install_packages
install_docker
create_identity
install_files
install_config
install_dirs
install_units
start_services

log "installed $BEAUT_INSTALL_ROLE ${BEAUT_INSTALL_NAME} on ${BEAUT_INSTALL_HOST}"
log "config: ${BEAUT_CONFIG_DIR}/beaut.conf"
log "state:  ${BEAUT_STATE_DIR}"
log "user:   ${BEAUT_USER} (group ${BEAUT_GROUP}, passwordless sudo)"
