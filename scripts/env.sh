#!/usr/bin/env bash
# scripts/env.sh — layer 2: identity, tree, config, runtime scripts.
#   ./scripts/env.sh <orchestrator|router|worker|client> [ORCHESTRATOR_IP]
set -euo pipefail
[ "$(id -u)" = 0 ] || die "run as root"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

ROLE="${1:?usage: scripts/env.sh <orchestrator|router|worker|client> [ORCHESTRATOR_IP]}"
ORCH_IP="${2:-${ORCHESTRATOR_IP:-}}"
PREFIX="${PREFIX:-/usr/local}"
BIN_DIR="$PREFIX/bin"; LIB_DIR="$PREFIX/lib/beaut"
ENV_DIR="${ENV_DIR:-/etc/beaut}"; STATE_DIR="${STATE_DIR:-/var/lib/beaut}"
SU="${SERVICE_USER:-beaut}"; SG="${SERVICE_GROUP:-beaut}"
CONF="$ENV_DIR/beaut.conf"; SECRET="$ENV_DIR/beaut.env"

# ── 1. build layer (chain) ─────────────────────────────────
log "layer 1: build"
bash "$HERE/build.sh" ${BEAUT_FORCE_BUILD:+--force}

# ── 2. identity ────────────────────────────────────────────
log "user/group"
getent group "$SG" >/dev/null || groupadd -r "$SG"
getent passwd "$SU" >/dev/null || useradd -r -M -g "$SG" -s /usr/sbin/nologin -d "$STATE_DIR" "$SU"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
  usermod -aG "$SG" "$SUDO_USER"; log "group member: $SUDO_USER (re-login)"
fi

# ── 3. cpu policy: ceil(2/3), distinct physical cores, >=1 free ──
TOTAL=$(nproc)
WORKERS=$(( (TOTAL * 2 + 2) / 3 ))
(( WORKERS > TOTAL - 1 )) && WORKERS=$(( TOTAL - 1 ))
(( WORKERS < 0 )) && WORKERS=0
mapfile -t PHYS < <(for f in /sys/devices/system/cpu/cpu[0-9]*/topology/core_id; do cat "$f"; done 2>/dev/null | sort -n | uniq)
if [ ${#PHYS[@]} -eq 0 ]; then mapfile -t PHYS < <(seq 0 $(( TOTAL - 1 ))); fi
(( WORKERS > ${#PHYS[@]} )) && WORKERS=${#PHYS[@]}
CORES=()
for ((i=0;i<WORKERS;i++)); do
  cid="${PHYS[$i]}"; cpu=""
  for c in /sys/devices/system/cpu/cpu[0-9]*; do
    [ "$(cat "$c/topology/core_id" 2>/dev/null)" = "$cid" ] && { cpu="${c##*/cpu}"; break; }
  done
  CORES+=("${cpu:-$i}")
done
log "cpu: total=$TOTAL workers=$WORKERS pinned=[${CORES[*]:-none}] free=$(( TOTAL - WORKERS ))"

# ── 4. tree ────────────────────────────────────────────────
log "file tree"
install -d -m 0755 "$BIN_DIR" "$LIB_DIR"
install -d -m 0750 -o root -g "$SG" "$ENV_DIR"
install -d -m 2770 -o "$SU" -g "$SG" "$STATE_DIR" "$STATE_DIR/archive" /var/log/beaut
[ -f "$STATE_DIR/log.enc" ] || install -m 0660 -o "$SU" -g "$SG" /dev/null "$STATE_DIR/log.enc"

# ── 5. config split: public conf vs secret ──
set_kv() { # file key value
  local f="$1" k="$2" v="$3" t
  [ -f "$f" ] || : > "$f"
  t="$(mktemp)"; grep -q "^$k=" "$f" 2>/dev/null && sed "s|^$k=.*|$k=$v|" "$f" >"$t" || { cat "$f" >"$t"; printf '%s=%s\n' "$k" "$v" >>"$t"; }
  cat "$t" > "$f"; rm -f "$t"
}
log "config: $CONF (0640 root:$SG)  $SECRET (0600 root:root)"
chmod 0640 "$CONF" 2>/dev/null || true; chown root:"$SG" "$CONF" 2>/dev/null || true
chmod 0600 "$SECRET" 2>/dev/null || true

set_kv "$CONF" BEAUT_DOMAIN "$([ "$ROLE" = router ] && echo vm || echo "$ROLE")"
set_kv "$CONF" BEAUT_STATE_DIR "$STATE_DIR"
set_kv "$CONF" BEAUT_ETC_DIR "$ENV_DIR"
set_kv "$CONF" BEAUT_IF "${BEAUT_IF:-$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}' || echo lo)}"
set_kv "$CONF" BEAUT_HEARTBEAT_S "${BEAUT_HEARTBEAT_S:-30}"
set_kv "$CONF" BEAUT_POLL_S "${BEAUT_POLL_S:-3}"
set_kv "$CONF" BEAUT_STALE_S "${BEAUT_STALE_S:-90}"
set_kv "$CONF" BEAUT_WORKERS "$WORKERS"
set_kv "$CONF" BEAUT_CORE_LIST "${CORES[*]:-}"
set_kv "$CONF" SALV_COEF "${SALV_COEF:-1/3}"
set_kv "$CONF" SCHEDULER_RESERVE_NODES "${SCHEDULER_RESERVE_NODES:-1}"
set_kv "$CONF" ROUTER_LISTEN "127.0.0.1"
set_kv "$CONF" ROUTER_PORT "${ROUTER_PORT:-7700}"
set_kv "$CONF" BEAUT_ALLOW_EXEC "${BEAUT_ALLOW_EXEC:-0}"
set_kv "$CONF" BEAUT_EXEC_DOMAINS "${BEAUT_EXEC_DOMAINS:-}"
case "$ROLE" in
  orchestrator) set_kv "$CONF" ORCHESTRATOR_IP "127.0.0.1" ;;
  *) [ -n "$ORCH_IP" ] || die "$ROLE needs ORCHESTRATOR_IP"
     set_kv "$CONF" ORCHESTRATOR_IP "$ORCH_IP" ;;
esac

if [ -n "${BEAUT_PASSWORD:-}" ]; then
  set_kv "$SECRET" BEAUT_PASSWORD "$BEAUT_PASSWORD"
  chmod 0600 "$SECRET"; chown root:root "$SECRET"
fi

# ── 6. render templates → runtime scripts ──
log "runtime scripts (from templates + sed var replacement)"
render() { # render <template> <output>
  local t="$1" o="$2"
  sed \
    -e "s|@PREFIX@|$PREFIX|g" \
    -e "s|@BIN_DIR@|$BIN_DIR|g" \
    -e "s|@LIB_DIR@|$LIB_DIR|g" \
    -e "s|@ENV_DIR@|$ENV_DIR|g" \
    -e "s|@BEAUT_ETC_DIR@|$ENV_DIR|g" \
    -e "s|@BEAUT_CONF@|$CONF|g" \
    -e "s|@BEAUT_SECRET@|$SECRET|g" \
    -e "s|@BEAUT_STATE_DIR@|$STATE_DIR|g" \
    -e "s|@BEAUT_IF@|${BEAUT_IF:-lo}|g" \
    -e "s|@BEAUT_TOOL@|$BIN_DIR/beaut-tool|g" \
    -e "s|@BEAUT_HEARTBEAT_S@|$(grep '^BEAUT_HEARTBEAT_S=' "$CONF" 2>/dev/null | cut -d= -f2 | head -1)|g" \
    -e "s|@ROLE@|$ROLE|g" \
    -e "s|@SU@|$SU|g" \
    -e "s|@SG@|$SG|g" \
    -e "s|@CONF@|$CONF|g" \
    -e "s|@STATE_DIR@|$STATE_DIR|g" \
    "$t" > "$o"
}

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
LockPersonality=yes
MemoryAccounting=yes
IPAddressAllow=0.0.0.0/0'

# shared lib + CLI
render "templates/beaut-lib.sh.tmpl" "$LIB_DIR/beaut-lib"
chmod 0644 "$LIB_DIR/beaut-lib"
render "templates/beaut-cli.sh.tmpl" "$BIN_DIR/beaut"
sed -i "s|@HARDEN@|$HARDEN|g" "$BIN_DIR/beaut" 2>/dev/null || true
chmod 0755 "$BIN_DIR/beaut"

# admin helpers
render "templates/beaut-signup.sh.tmpl" "$BIN_DIR/beaut-signup"
render "templates/beaut-approve.sh.tmpl" "$BIN_DIR/beaut-approve"
render "templates/beaut-ban.sh.tmpl" "$BIN_DIR/beaut-ban"
chmod 0755 "$BIN_DIR/beaut-signup" "$BIN_DIR/beaut-approve" "$BIN_DIR/beaut-ban"

# sudoers
render "templates/sudoers.tmpl" "$ENV_DIR/../sudoers.d/beaut"
SUDOERS="/etc/sudoers.d/beaut"
install -m 0440 "$ENV_DIR/../sudoers.d/beaut" "$SUDOERS" 2>/dev/null || {
  render "templates/sudoers.tmpl" "$SUDOERS"
  chmod 0440 "$SUDOERS"
}
visudo -cf "$SUDOERS" >/dev/null || die "invalid sudoers drop-in"
log "sudoers: $SUDOERS"

# ── 7. systemd unit files from templates ──
log "systemd unit templates"
render "templates/beaut-orchestrator.service.tmpl" "/tmp/beaut-orchestrator.service"
sed -i "s|@HARDEN@|$HARDEN|g" "/tmp/beaut-orchestrator.service"
install -m 0644 "/tmp/beaut-orchestrator.service" /etc/systemd/system/beaut-orchestrator.service

render "templates/beaut-heartbeat.service.tmpl" "/tmp/beaut-heartbeat.service"
sed -i "s|@HARDEN@|$HARDEN|g" "/tmp/beaut-heartbeat.service"
install -m 0644 "/tmp/beaut-heartbeat.service" /etc/systemd/system/beaut-heartbeat.service

render "templates/beaut-heartbeat.timer.tmpl" /etc/systemd/system/beaut-heartbeat.timer

if [ "$ROLE" = router ]; then
  render "templates/beaut-router.service.tmpl" "/tmp/beaut-router.service"
  sed -i "s|@HARDEN@|$HARDEN|g" "/tmp/beaut-router.service"
  install -m 0644 "/tmp/beaut-router.service" /etc/systemd/system/beaut-router.service
fi

# one pinned unit per worker core
rm -f /etc/systemd/system/beaut-worker@*.service
i=0
for cpu in ${CORES[*]:-}; do
  render "templates/beaut-worker.service.tmpl" "/tmp/beaut-worker@$i.service"
  sed -i "s/@INDEX@/$i/g; s/@CPU@/$cpu/g; s|@HARDEN@|$HARDEN|g" "/tmp/beaut-worker@$i.service"
  install -m 0644 "/tmp/beaut-worker@$i.service" "/etc/systemd/system/beaut-worker@$i.service"
  i=$(( i + 1 ))
done
rm -f /tmp/beaut-*.service /tmp/beaut-*.timer

systemctl daemon-reload
systemctl enable --now beaut-heartbeat.timer beaut-orchestrator 2>/dev/null || true
[ "$ROLE" = router ] && systemctl enable --now beaut-router 2>/dev/null || true
for ((j=0;j<${WORKERS:-0};j++)); do systemctl enable --now "beaut-worker@$j" 2>/dev/null || true; done

# hand the built binaries to the installer (layer 3)
printf 'BEAUT_BIN=%s\nBEAUT_WORKERS=%s\nBEAUT_CORES=%s\nBEAUT_ROLE=%s\nBEAUT_ORCH_IP=%s\n' \
  "$HERE/.." "$WORKERS" "${CORES[*]:-}" "$ROLE" "$ORCH_IP" > "$HERE/../.deploy-state"
log "layer 2 done"
