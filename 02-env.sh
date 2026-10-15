#!/usr/bin/env bash
# 02-env.sh — layer 2: identity, tree, config, runtime scripts. Calls 01-build.sh.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"

ROLE="${1:?usage: 02-env.sh <orchestrator|router|worker|client> [ORCHESTRATOR_IP]}"
ORCH_IP="${2:-${ORCHESTRATOR_IP:-}}"
PREFIX="${PREFIX:-/usr/local}"
BIN_DIR="$PREFIX/bin"; LIB_DIR="$PREFIX/lib/beaut"
ENV_DIR="${ENV_DIR:-/etc/beaut}"; STATE_DIR="${STATE_DIR:-/var/lib/beaut}"
SU="${SERVICE_USER:-beaut}"; SG="${SERVICE_GROUP:-beaut}"
CONF="$ENV_DIR/beaut.conf"; SECRET="$ENV_DIR/beaut.env"

# ── 1. build layer (chain) ─────────────────────────────────
log "layer 1: build"
bash "$HERE/01-build.sh" ${BEAUT_FORCE_BUILD:+--force}

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

# ── 5. config split: public conf (group-readable) vs secret (root-only) ──
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
# exec is OFF by default — see the note at the bottom
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

# ── 6. runtime: CLI ────────────────────────────────────────
log "runtime scripts"
cat > "$LIB_DIR/beaut-lib" <<'LIB'
# shared shell helpers — sourced by every beaut script
CONF="${BEAUT_CONF:-/etc/beaut/beaut.conf}"
SECRET="${BEAUT_SECRET:-/etc/beaut/beaut.env}"
[ -r "$CONF" ] && . "$CONF"
[ -r "$SECRET" ] && . "$SECRET"
T="${BEAUT_TOOL:-/usr/local/bin/beaut-tool}"
LOG="${BEAUT_STATE_DIR:-/var/lib/beaut}/log.enc"
me=$(hostname -s)
myip() {
  ip -4 addr show "${BEAUT_IF:-lo}" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1
}
need_pw() { : "${BEAUT_PASSWORD:?BEAUT_PASSWORD unset — run via sudo or export it}"; }
alert() {
  printf '%s %s\n' "$(date -Is)" "$*" >> /var/log/beaut/connections.log
  command -v wall >/dev/null 2>&1 && printf 'beaut: %s\n' "$*" | wall -n 2>/dev/null || true
}
LIB
chmod 0644 "$LIB_DIR/beaut-lib"

cat > "$BIN_DIR/beaut" <<'CLI'
#!/usr/bin/env bash
set -uo pipefail
. /usr/local/lib/beaut/beaut-lib
cmd="${1:-help}"; shift || true
case "$cmd" in
  init)
    need_pw
    lvl=$("$T" auth "$BEAUT_PASSWORD") || { echo "identity not approved" >&2; exit 1; }
    echo "level=$lvl | $("$T" role) | ip=$(myip)" ;;
  heartbeat) need_pw; "$T" heartbeat "$LOG" "$me" "$(myip)" "$BEAUT_PASSWORD" ;;
  peers)   need_pw; "$T" peers "$LOG" "$BEAUT_PASSWORD" ;;
  pick)    need_pw; "$T" pick "$LOG" "$BEAUT_PASSWORD" ;;
  retain)  "$T" retain ;;
  run)
    need_pw
    dom="${1:?domain}"; shift || true
    [ "$#" -gt 0 ] || { echo "usage: beaut run <domain> <cmd>" >&2; exit 1; }
    task="$*"
    { read -r best; read -r next; } < <("$T" pick "$LOG" "$BEAUT_PASSWORD")
    [ -n "$best" ] || { echo "no worker available" >&2; exit 1; }
    "$T" post "$LOG" "$me" task "${best}::user=${USER:-unknown}::NPROC=$("$T" cores)::domain=${dom}::${task}" "$BEAUT_PASSWORD"
    echo "posted -> $best (next: ${next:-none})" ;;
  watch)
    need_pw
    offset=0; seen=""
    trap 'exit 0' TERM INT
    while :; do
      out=$("$T" read "$LOG" "$offset" "$BEAUT_PASSWORD" 2>/dev/null || true)
      cnt=$("$T" read "$LOG" "$offset" "$BEAUT_PASSWORD" 2>&1 >/dev/null || echo 0)
      while IFS=$'\t' read -r ts worker action payload; do
        [ -n "${worker:-}" ] || continue
        [ "$worker" = "$me" ] && continue
        case "$action" in
          heartbeat)
            case " $seen " in *" $worker "*) ;; *)
              seen="$seen $worker"; alert "WORKER_CONNECT $worker ${payload%%:*}" ;;
            esac ;;
          task)
            target="${payload%%::*}"; rest="${payload#*::}"
            nproc="${rest%%::*}"; rest="${rest#*::}"
            dom="${rest%%::*}"; rest="${rest#*::}"; dom="${dom#domain=}"
            [ "$target" = "$(myip)" ] || [ "$target" = "*" ] || continue
            if [ "$("$T" role)" = router ]; then
              "$T" post "$LOG" "$me" route "${target}::${dom}" "$BEAUT_PASSWORD"
              alert "TRAFFIC_ROUTE $dom -> $target"
              continue
            fi
            if [ "${BEAUT_ALLOW_EXEC:-0}" != 1 ]; then
              alert "EXEC_BLOCKED $dom from $worker (BEAUT_ALLOW_EXEC=0)"; continue
            fi
            if [ -n "${BEAUT_EXEC_DOMAINS:-}" ] && [[ ",${BEAUT_EXEC_DOMAINS}," != *",${dom},"* ]]; then
              alert "EXEC_BLOCKED domain=$dom not in allowlist"; continue
            fi
            alert "EXEC_START $dom from $worker"
            if timeout "${BEAUT_EXEC_TIMEOUT_S:-300}" bash -c "$rest"; then
              "$T" post "$LOG" "$me" result "$(myip)::${dom}" "$BEAUT_PASSWORD"
            else
              "$T" post "$LOG" "$me" fail "$(myip)::${dom}" "$BEAUT_PASSWORD"
            fi ;;
        esac
      done <<< "$out"
      offset=$(( offset + ${cnt:-0} ))
      sleep "${BEAUT_POLL_S:-3}"
    done ;;
  help|*)
    cat >&2 <<H
usage: beaut <cmd>
  init                 verify identity + show role
  heartbeat            post one heartbeat
  peers | pick         scheduler view
  run <domain> <cmd>   post a task to the best worker
  watch                dispatch loop (used by the service)
  retain               prune/archive the log
H
    ;;
esac
CLI
chmod 0755 "$BIN_DIR/beaut"

# ── 7. admin helpers ───────────────────────────────────────
cat > "$BIN_DIR/beaut-signup" <<'S'
#!/usr/bin/env bash
set -uo pipefail
. /usr/local/lib/beaut/beaut-lib
need_pw
E="${BEAUT_ETC_DIR:-/etc/beaut}"
"$T" join "$E/pending.tsv" "$BEAUT_PASSWORD"
echo "ask an admin: sudo beaut-approve <id> <level>"
S
cat > "$BIN_DIR/beaut-approve" <<'A'
#!/usr/bin/env bash
set -uo pipefail
E="${BEAUT_ETC_DIR:-/etc/beaut}"
T="${BEAUT_TOOL:-/usr/local/bin/beaut-tool}"
[ "$#" -ge 1 ] || { echo "usage: beaut-approve <id> [level=2]" >&2; exit 1; }
"$T" approve "$E/pending.tsv" "$E/priv.tsv" "$1" "${2:-2}" && echo "approved $1 level ${2:-2}"
A
cat > "$BIN_DIR/beaut-ban" <<'B'
#!/usr/bin/env bash
set -uo pipefail
E="${BEAUT_ETC_DIR:-/etc/beaut}"
T="${BEAUT_TOOL:-/usr/local/bin/beaut-tool}"
[ "$#" -eq 1 ] || { echo "usage: beaut-ban <id>" >&2; exit 1; }
enc="$("$T" encode "$1" | cut -c1-3)"
[ -f "$E/priv.tsv" ] || exit 0
grep -v "$enc" "$E/priv.tsv" > "$E/priv.tsv.t" || true
mv "$E/priv.tsv.t" "$E/priv.tsv"
echo "banned $1"
B
chmod 0755 "$BIN_DIR/beaut-signup" "$BIN_DIR/beaut-approve" "$BIN_DIR/beaut-ban"

# ── 8. sudoers: group can drive beaut without a password ───
SUDOERS="/etc/sudoers.d/beaut"
cat > "$SUDOERS" <<EOF
# managed by 02-env.sh — members of $SG run beaut without a password
%$SG ALL=(root) NOPASSWD: $BIN_DIR/beaut, $BIN_DIR/beaut-tool, $BIN_DIR/beaut-signup
%$SG ALL=(root) NOPASSWD: /usr/bin/systemctl status beaut-*, /usr/bin/journalctl -u beaut-*
EOF
chmod 0440 "$SUDOERS"
visudo -cf "$SUDOERS" >/dev/null || die "invalid sudoers drop-in"
log "sudoers: $SUDOERS"

# hand the built binaries to the installer (layer 3)
printf 'BEAUT_BIN=%s\nBEAUT_WORKERS=%s\nBEAUT_CORES=%s\nBEAUT_ROLE=%s\nBEAUT_ORCH_IP=%s\n' \
  "$HERE" "$WORKERS" "${CORES[*]:-}" "$ROLE" "$ORCH_IP" > "$HERE/.deploy-state"
log "layer 2 done"
