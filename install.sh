#!/usr/bin/env bash
# install.sh — entry point. Calls env.sh which calls build.sh.
#   sudo ./install.sh <orchestrator|router|worker|client> [ORCHESTRATOR_IP]
#   sudo ./install.sh --serve [PORT]        publish the scripts for curl bootstrap
#   ./install.sh --status | --uninstall
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }
PREFIX="${PREFIX:-/usr/local}"
BIN_DIR="$PREFIX/bin"
ENV_DIR="${ENV_DIR:-/etc/beaut}"; STATE_DIR="${STATE_DIR:-/var/lib/beaut}"
SU="${SERVICE_USER:-beaut}"; SG="${SERVICE_GROUP:-beaut}"
CONF="$ENV_DIR/beaut.conf"

# ── publish the three scripts for a curl bootstrap ─────────
do_serve() {
  local port="${1:-8080}" d ip
  d="$(mktemp -d)"
  cp "$HERE/install.sh" "$HERE/build.sh" "$HERE/env.sh" "$d/"
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo "$ip" > "$d/orch.host"
  tar czf "$d/beaut.tgz" -C "$d" install.sh build.sh env.sh orch.host
  ( cd "$d" && sha256sum beaut.tgz > beaut.tgz.sha256 )
  chmod 644 "$d"/*
  log "serving on :$port — sha256 $(cut -d' ' -f1 "$d/beaut.tgz.sha256" | cut -c1-16)…"
  cat <<EOT

  on the new node (verify before running):
    curl -fsSLO http://$ip:$port/beaut.tgz
    curl -fsSL  http://$ip:$port/beaut.tgz.sha256 | sha256sum -c -
    tar xzf beaut.tgz && sudo BEAUT_PASSWORD='...' ./install.sh worker $ip

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

case "${1:-}" in
  --serve) shift; do_serve "$@" ;;
  --status) do_status; exit 0 ;;
  --uninstall) do_uninstall; exit 0 ;;
  ""|--help|-h) sed -n '2,6p' "$0"; exit 0 ;;
esac

# ── install path ───────────────────────────────────────────
[ "$(id -u)" = 0 ] || die "run as root: sudo $0 $*"
# orchestrator IP: explicit arg > env > host we were served from > self
resolve_orch() {
  if [ "$ROLE" = orchestrator ]; then echo "127.0.0.1"; return; fi
  [ -n "${ORCH_IP:-}" ]          && { echo "$ORCH_IP"; return; }
  [ -f "$HERE/orch.host" ]       && { cat "$HERE/orch.host"; return; }
  die "no orchestrator IP — pass it as arg 2, or deploy from a --serve tarball"
}
ROLE="$1"; ORCH_IP="${2:-${ORCHESTRATOR_IP:-}}"
ORCH_IP="$(resolve_orch)"
log "orchestrator = $ORCH_IP"
case "$ROLE" in orchestrator|router|worker|client) : ;; *) die "unknown role: $ROLE" ;; esac

log "installing"
bash "$HERE/env.sh" "$ROLE" "$ORCH_IP"
[ -f "$HERE/.deploy-state" ] && . "$HERE/.deploy-state"

log "installing binaries"
install -m 0755 "$BEAUT_BIN/beaut-tool" "$BIN_DIR/beaut-tool"
install -m 0755 "$BEAUT_BIN/beaut-router" "$BIN_DIR/beaut-router"
chown root:root "$BIN_DIR/beaut-tool" "$BIN_DIR/beaut-router"

# ── first identity: bootstrap the admin if priv.tsv is empty ──
if [ ! -s "$ENV_DIR/priv.tsv" ] && [ -n "${BEAUT_PASSWORD:-}" ]; then
  log "bootstrapping admin identity"
  install -m 0660 -o root -g "$SG" /dev/null "$ENV_DIR/pending.tsv"
  id="$("$BIN_DIR/beaut-tool" join "$ENV_DIR/pending.tsv" "$BEAUT_PASSWORD" | awk -F'id=' '/id=/{print $2}' | cut -d' ' -f1)"
  "$BIN_DIR/beaut-tool" approve "$ENV_DIR/pending.tsv" "$ENV_DIR/priv.tsv" "$id" 3
  install -m 0640 -o root -g "$SG" "$ENV_DIR/priv.tsv" "$ENV_DIR/priv.tsv"
  log "admin id=$id level=3"
fi

# ── systemd ────────────────────────────────────────────────
log "systemd units"
HARDEN='NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
RestrictAddressFamilies=AF_INET AF_INET6
LockPersonality=yes
MemoryAccounting=yes
IPAddressAllow=0.0.0.0/0'

cat > /etc/systemd/system/beaut-orchestrator.service <<EOF
[Unit]
Description=Beaut orchestrator ($ROLE) — dispatch, routing, alerts
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SU
Group=$SG
EnvironmentFile=$CONF
ExecStart=$BIN_DIR/beaut watch
Restart=on-failure
RestartSec=3
ReadWritePaths=$STATE_DIR /var/log/beaut
$HARDEN

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/beaut-heartbeat.service <<EOF
[Unit]
Description=Beaut heartbeat
[Service]
Type=oneshot
User=$SU
Group=$SG
EnvironmentFile=$CONF
ExecStart=$BIN_DIR/beaut heartbeat
$HARDEN
EOF

cat > /etc/systemd/system/beaut-heartbeat.timer <<EOF
[Unit]
Description=Beaut heartbeat
[Timer]
OnBootSec=15s
OnUnitActiveSec=${BEAUT_HEARTBEAT_S:-30}s
AccuracySec=5s
[Install]
WantedBy=timers.target
EOF

if [ "$ROLE" = router ]; then
  cat > /etc/systemd/system/beaut-router.service <<EOF
[Unit]
Description=Beaut router (front door -> orchestrator)
After=network-online.target
[Service]
Type=simple
User=$SU
Group=$SG
EnvironmentFile=$CONF
ExecStart=$BIN_DIR/beaut-router
Restart=on-failure
RestartSec=2
$HARDEN

[Install]
WantedBy=multi-user.target
EOF
fi

# one pinned unit per worker core
rm -f /etc/systemd/system/beaut-worker@*.service
i=0
for cpu in ${BEAUT_CORES:-}; do
  cat > "/etc/systemd/system/beaut-worker@$i.service" <<EOF
[Unit]
Description=Beaut worker $i (core $cpu)
After=beaut-orchestrator.service
BindsTo=beaut-orchestrator.service

[Service]
Type=simple
User=$SU
Group=$SG
CPUAffinity=$cpu
Nice=5
ExecStart=/bin/sh -c 'while :; do sleep 3600; done'
$HARDEN

[Install]
WantedBy=multi-user.target
EOF
  i=$(( i + 1 ))
done

systemctl daemon-reload
systemctl enable --now beaut-heartbeat.timer beaut-orchestrator
[ "$ROLE" = router ] && systemctl enable --now beaut-router
for ((j=0;j<${BEAUT_WORKERS:-0};j++)); do systemctl enable --now "beaut-worker@$j"; done

echo
log "done — role=$ROLE  workers=${BEAUT_WORKERS:-0}  cores=[${BEAUT_CORES:-none}]"
echo "  journalctl -fu beaut-orchestrator      # dispatch + wall alerts"
echo "  tail -f /var/log/beaut/connections.log # WORKER_CONNECT / TRAFFIC_ROUTE"
echo "  sudo beaut peers                       # no password (group $SG)"
echo "  re-login (or newgrp $SG) to pick up the group"
