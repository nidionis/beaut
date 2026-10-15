#!/usr/bin/env bash
# 00-install.sh — layer 3: entry point
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

PREFIX="${PREFIX:-/usr/local}"
BIN_DIR="$PREFIX/bin"
ENV_DIR="${ENV_DIR:-/etc/beaut}"
STATE_DIR="${STATE_DIR:-/var/lib/beaut}"
SU="${SERVICE_USER:-beaut}"
SG="${SERVICE_GROUP:-beaut}"
CONF="$ENV_DIR/beaut.conf"

ROLE="${1:-orchestrator}"
ORCH_IP="${2:-}"
[ -z "$ORCH_IP" ] && {
    ORCH_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '/via/ {print $NF}' || echo "127.0.0.1")
}
[ -z "$ORCH_IP" ] && die "no orchestrator IP found — pass it as second arg or export ORCHESTRATOR_IP"

do_install() {
  log "role=$ROLE orch_ip=$ORCH_IP"
  bash "$HERE/02-env.sh" "$ROLE" "$ORCH_IP"
  bash "$HERE/01-build.sh" --force          # force rebuild every time, no caching
}

do_serve() {
  local port="${1:-8080}"
  mkdir -p "$HERE/tmp"
  cp "$HERE/00-install.sh" "$HERE/01-build.sh" "$HERE/02-env.sh" "$HERE/tmp/"
  tar czf "$HERE/tmp/beaut.tgz" -C "$HERE/tmp" 00-install.sh 01-build.sh 02-env.sh orch.host
  sha256sum "$HERE/tmp/beaut.tgz" > "$HERE/tmp/beaut.tgz.sha256"
  python3 -m http.server "$port" --directory "$HERE/tmp"
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
    [ -e "$u" ] && systemctl disable --now "$(basename "$u")" 2>/dev/null || true
  done
  rm -f /etc/systemd/system/beaut-*.service /etc/sudoers.d/beaut
  systemctl daemon-reload
  log "units removed — state kept in $STATE_DIR"
}

case "${1:-}" in
  --serve) shift; do_serve "$@" ;;
  --status) do_status ;;
  --uninstall) do_uninstall ;;
  ""|--help|-h) sed -n '2,8p' "$0"; exit 0 ;;
  *) do_install "$ROLE" "$ORCH_IP" ;;
esac
