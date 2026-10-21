#!/usr/bin/env bash
# install.sh — beaut single entry point (the only user-facing script besides config.env)
#
#   sudo ./install.sh                  install (reads config.env)
#   sudo ./install.sh --role ROLE [IP] quick non-interactive install
#   sudo ./install.sh --serve [PORT]   publish bootstrap tarball (curl | bash)
#   sudo ./install.sh --status         show systemd status
#   sudo ./install.sh --uninstall      remove systemd units
#   sudo ./install.sh deploy [TARGET]  deploy to ORCHESTRATOR / ROUTER / DOMAIN via ssh
#   ./install.sh --help                show this help
#
# Config file: config.env  (mandatory: BEAUT_PASSWORD, ROLE)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
info() { printf '     %s\n' "$*"; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

PREFIX="${PREFIX:-/usr/local}"
BIN_DIR="$PREFIX/bin"
ENV_DIR="${ENV_DIR:-/etc/beaut}"
STATE_DIR="${STATE_DIR:-/var/lib/beaut}"
SU="${SERVICE_USER:-beaut}"
SG="${SERVICE_GROUP:-beaut}"
CONF="$ENV_DIR/beaut.conf"

load_config() {
  local f="${1:-config.env}"
  [ -f "$f" ] || die "config file not found: $f (copy config.env.example to config.env and edit)"
  # shellcheck disable=SC1090
  . "$f"
  : "${BEAUT_PASSWORD:?config.env must define BEAUT_PASSWORD}"
  : "${ROLE:?config.env must define ROLE (orchestrator|router|worker|client)}"
  export BEAUT_PASSWORD ROLE IP_ORCHESTRATOR IP_ROUTER IP_DOMAIN NEIGHBOURS WORKERS
  log "config loaded from $f (role=$ROLE)"
}

do_install() {
  local role="$1" orch_ip="${2:-}"
  [ "$(id -u)" = 0 ] || die "run as root: sudo $0 $*"

  log "layers 1 + 2"
  bash "$HERE/scripts/env.sh" "$role" "$orch_ip"
  . "$HERE/.deploy-state"

  log "installing binaries to $BIN_DIR"
  install -d -m 0755 "$BIN_DIR"
  install -m 0755 "$BEAUT_BIN/beaut-tool" "$BIN_DIR/beaut-tool"
  install -m 0755 "$BEAUT_BIN/beaut-router" "$BIN_DIR/beaut-router"
  chown root:root "$BIN_DIR/beaut-tool" "$BIN_DIR/beaut-router"

  # config file into /etc/beaut (system copy)
  install -d -m 0750 -o root -g "$SG" "$ENV_DIR"
  if [ -f config.env ]; then
    install -m 0640 -o root -g "$SG" config.env "$CONF"
  fi

  # first identity: bootstrap the admin if priv.tsv is empty
  if [ ! -s "$ENV_DIR/priv.tsv" ] && [ -n "${BEAUT_PASSWORD:-}" ]; then
    log "bootstrapping admin identity"
    install -m 0660 -o root -g "$SG" /dev/null "$ENV_DIR/pending.tsv"
    id="$("$BIN_DIR/beaut-tool" join "$ENV_DIR/pending.tsv" "$BEAUT_PASSWORD" \
      | awk -F'id=' '/id=/{print $2}' | cut -d' ' -f1)"
    "$BIN_DIR/beaut-tool" approve "$ENV_DIR/pending.tsv" "$ENV_DIR/priv.tsv" "$id" 3
    install -m 0640 -o root -g "$SG" "$ENV_DIR/priv.tsv" "$ENV_DIR/priv.tsv"
    log "admin id=$id level=3"
  fi

  echo
  log "done — role=$ROLE  workers=${BEAUT_WORKERS:-0}  cores=[${BEAUT_CORES:-none}]"
  echo "  journalctl -fu beaut-orchestrator      # dispatch + wall alerts"
  echo "  tail -f /var/log/beaut/connections.log # WORKER_CONNECT / TRAFFIC_ROUTE"
  echo "  sudo beaut peers                       # no password (group $SG)"
  echo "  re-login (or newgrp $SG) to pick up the group"
}

do_serve() {
  local port="${1:-8080}" d ip
  d="$(mktemp -d)"
  cp "$HERE/install.sh" "$HERE/config.env" "$HERE/scripts/build.sh" "$HERE/scripts/env.sh" "$d/"
  cp -r "$HERE/templates" "$d/templates"
  tar czf "$d/beaut.tgz" -C "$d" install.sh config.env scripts templates
  ( cd "$d" && sha256sum beaut.tgz > beaut.tgz.sha256 )
  chmod 644 "$d"/*
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo "$ip" > "$d/orch.host"
  tar czf "$d/beaut.tgz" -C "$d" install.sh config.env scripts templates orch.host
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  log "serving on :$port — sha256 $(cut -d' ' -f1 "$d/beaut.tgz.sha256" | cut -c1-16)…"
  cat <<EOT

  on the new node (verify before running):
    curl -fsSLO http://$ip:$port/beaut.tgz
    curl -fsSL  http://$ip:$port/beaut.tgz.sha256 | sha256sum -c -
    tar xzf beaut.tgz && sudo BEAUT_PASSWORD='...' ./install.sh

EOT
  exec python3 -m http.server "$port" --directory "$d"
}

do_status() {
  systemctl status beaut-orchestrator beaut-heartbeat.timer beaut-router --no-pager 2>/dev/null || true
  systemctl list-units 'beaut-worker@*' --no-pager 2>/dev/null || true
  command -v beaut >/dev/null && sudo -n beaut peers 2>/dev/null || true
}

do_uninstall() {
  [ "$(id -u)" = 0 ] || die "run as root"
  systemctl disable --now beaut-orchestrator beaut-heartbeat.timer beaut-router 2>/dev/null || true
  for u in /etc/systemd/system/beaut-worker@*.service; do
    [ -e "$u" ] || continue
    systemctl disable --now "$(basename "$u")" 2>/dev/null || true
  done
  rm -f /etc/systemd/system/beaut-*.service /etc/systemd/system/beaut-*.timer /etc/sudoers.d/beaut
  systemctl daemon-reload
  log "units removed — state kept in $STATE_DIR"
}

# ── helpers: local non-127 IP (RFC1918 preferred) ──────────────────────────
detect_local_ip() {
  # first non-loopback IPv4 address (typically 192.168.x / 10.x / 172.16-31.x)
  ip -4 addr show 2>/dev/null \
    | awk '/inet /{print $2}' | cut -d/ -f1 \
    | grep -v '^127\.' | head -1 || true
}

is_local() {
  local ip="$1"
  [ "$ip" = "127.0.0.1" ] || [ "$ip" = "localhost" ] && return 0
  return 1
}

# ── deploy: push + install on ORCHESTRATOR / ROUTER / DOMAIN via ssh ──────
do_deploy() {
  local target="${1:-}"
  [ "$(id -u)" = 0 ] || die "run as root: sudo $0 deploy [TARGET]"

  # load config for remote targets (non-fatal if missing)
  if [ -f config.env ]; then . config.env; fi

  local local_ip; local_ip="$(detect_local_ip)"
  [ -n "$local_ip" ] || local_ip="127.0.0.1"

  # build the target list
  local targets=()
  [ -n "$target" ]        && targets+=("$target")
  [ -n "${IP_ORCHESTRATOR:-}" ] && targets+=("$IP_ORCHESTRATOR")
  [ -n "${IP_ROUTER:-}" ]   && targets+=("$IP_ROUTER")
  [ -n "${IP_DOMAIN:-}" ]   && targets+=("$IP_DOMAIN")

  # de-duplicate
  local uniq=()
  for t in "${targets[@]}"; do
    local skip=0
    for u in "${uniq[@]}"; do [ "$u" = "$t" ] && skip=1; done
    [ "$skip" = 0 ] && uniq+=("$t")
  done
  targets=("${uniq[@]}")

  if [ "${#targets[@]}" -eq 0 ]; then
    log "no remote target (ORCHESTRATOR/ROUTER/DOMAIN) configured"
    log "-> deploying on localhost (${local_ip})"
    do_install "${ROLE:-orchestrator}" "$local_ip"
    return 0
  fi

  # ── build a deploy tarball ─────────────────────────────────────────────
  local d; d="$(mktemp -d)"
  mkdir -p "$d/scripts" "$d/templates"
  cp install.sh config.env "$d/"
  cp -r scripts/. "$d/scripts/"
  cp -r templates/. "$d/templates/"
  tar czf "$d/beaut.tgz" -C "$d" install.sh config.env scripts templates
  local tarball="$d/beaut.tgz"
  log "deploy package ready: $(du -h "$tarball" | awk '{print $1}')"

  local ok=0 fail=0
  for t in "${targets[@]}"; do
    echo
    log "━━━ deploying to $t ━━━"
    if is_local "$t"; then
      info "$t is local — installing directly"
      do_install "${ROLE:-orchestrator}" "$local_ip"
      ok=$((ok + 1))
      continue
    fi

    # check ssh reachability
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$t" true 2>/dev/null; then
      warn "ssh to $t unreachable — installing on localhost (${local_ip}) instead"
      do_install "${ROLE:-orchestrator}" "$local_ip"
      ok=$((ok + 1))
      continue
    fi

    # copy tarball via scp (sftp fallback)
    info "copying package to $t ..."
    if ! scp -q "$tarball" "${t}:~/beaut.tgz" 2>/dev/null; then
      warn "scp to $t failed — trying sftp"
      echo "put $tarball ~/beaut.tgz" | sftp -q "$t" >/dev/null 2>&1 \
        || { warn "scp/sftp to $t failed — installing on localhost instead"; do_install "${ROLE:-orchestrator}" "$local_ip"; ok=$((ok + 1)); continue; }
    fi

    # remote install via ssh
    info "running install on $t ..."
    if ssh -t "$t" "tar xzf ~/beaut.tgz && cd ~ && sudo ./install.sh --role ${ROLE:-orchestrator} $t" 2>/dev/null; then
      log "✓ $t deployed"
      ok=$((ok + 1))
    else
      warn "remote install on $t failed — installing on localhost (${local_ip}) instead"
      do_install "${ROLE:-orchestrator}" "$local_ip"
      ok=$((ok + 1))
    fi
  done

  rm -rf "$d"

  echo
  if [ "$fail" -eq 0 ]; then
    log "deploy complete — ${ok} target(s) installed"
  else
    warn "deploy finished with ${fail} failure(s), ${ok} success(es)"
  fi
}

case "${1:-}" in
  --serve)   shift; do_serve "$@" ;;
  --status)  do_status ;;
  --uninstall) do_uninstall ;;
  deploy)    shift; do_deploy "$@" ;;
  --role)
    shift
    [ "$#" -ge 1 ] || die "usage: $0 --role ROLE [ORCH_IP]"
    ROLE="$1"; ORCH_IP="${2:-127.0.0.1}"
    case "$ROLE" in orchestrator|router|worker|client) ;; *) die "unknown role: $ROLE" ;; esac
    [ "$ROLE" = orchestrator ] && ORCH_IP="127.0.0.1"
    export ROLE ORCH_IP
    do_install "$ROLE" "$ORCH_IP"
    ;;
  ""|--help|-h)
    sed -n '2,12p' "$0"
    exit 0
    ;;
  *)
    load_config config.env
    do_install "${ROLE:-orchestrator}" "${IP_ORCHESTRATOR:-}"
    ;;
esac
