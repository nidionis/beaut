#!/usr/bin/env bash
# lab/tests/run.sh — hermetic smoke tests for the lab prototype.
# No root, no network, no sshd. Needs ssh-keygen for the key tests.
#
# The suite is built one step at a time: enable a step, run the script, fix
# what fails, then move on. Steps 1-7 below stay commented as a roadmap until
# they are ready; each step generates the fixtures it needs.

set -u
LAB_ROOT=${1:-"$HOME/code/beaut/lab"}
USERKNOWNHOSTSFILE=$LAB_ROOT/.ssh/known_hosts 
BEAUT="$LAB_ROOT/beaut-lab"
TMP=/tmp/beaut-lab-test
rm -rf $TMP
#TMP=$(mktemp -d "${LAB_ROOT:-/tmp}/beaut-lab-test.XXXXXX")
#trap 'rm -rf "$TMP"' EXIT          # uncomment to clean up the temp tree

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$*"; }
no()  { fail=$((fail + 1)); printf 'FAIL %s\n' "$*"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3', got '$2')"; fi; }
yes_() { if eval "$2"; then ok "$1"; else no "$1"; fi; }

# ---- fixtures ----------------------------------------------------------------
export HOME="$TMP/home"; mkdir -p "$HOME"
export DIR="$TMP"
export STATE_DIR="$DIR/state"
export SHARED_DIR="$DIR/shared"
export CLIENT_KEYS="$DIR/clients" WORKER_KEYS="$DIR/workers"
export LAB_ADVANCED=/dev/null          # ignore config.advanced.env here
export LAB_CONFIG="$DIR/config.env"

mkdir -p "$SHARED_DIR"

cat > "$LAB_CONFIG" <<EOF
DOMAIN="test.lab"
ROLES="orchestrator,router,worker,client"
NAME="testorch"
ORCHESTRATOR_NAME=\$NAME
ORCHESTRATOR_ADDR="127.0.0.1"
ADMIN_PORT=8888
TUNNEL_USER="tunnel"
TUNNEL_PORT=22
TUNNEL_PORT_RANGE="22000-22099"
WORKER_STALE_SECONDS=2
SESSION_LEASE_SECONDS=3
KILL_GRACE_SECONDS=0
DIR=$DIR
CLIENT_KEYS=$CLIENT_KEYS
WORKER_KEYS=$WORKER_KEYS
STATE_DIR=$STATE_DIR
LOG_LEVEL="debug"
TIERS="guest 1 2048 16"
EOF

# ---- prerequisites -----------------------------------------------------------
if ! command -v ssh-keygen >/dev/null 2>&1; then
    echo "ssh-keygen not found: skipping lab tests" >&2
    exit 0
fi

# ---- keys --------------------------------------------------------------------
# Each host keeps its private key local; only public keys are shared/enrolled.
# Two hosts are "friends" once each accepts the other's public key.
keygen() { ssh-keygen -q -t ed25519 -N '' -C "$1" -f "$DIR/$1" >/dev/null; }
keygen alice

# ---- connection scan (alice -> friends) --------------------------------------
# Load the fixture config for the addresses the app itself reads.
# shellcheck disable=SC1090
. "$LAB_CONFIG"

# The orchestrator is mandatory; router and neighbours are best-effort.
FRIENDS=${FRIENDS:-$ORCHESTRATOR_ADDR}
[ -n "${ROUTER_ADDR:-}" ] && FRIENDS="$FRIENDS $ROUTER_ADDR"
while read -r name addr _rest; do
    case "$name" in ''|'#'*) continue ;; esac
    [ -n "$addr" ] && FRIENDS="$FRIENDS $addr"
done <<< "$FRIENDS"

scan_connection() {
    local addr=$1
    ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=$USERKNOWNHOSTSFILE -o LogLevel=ERROR \
        -i "$DIR/$NAME" "${NAME:-$TUNNEL_USER}@$addr" true
}

for ADDR in $FRIENDS; do
    if scan_connection "$ADDR"; then
        ok "ssh to $ADDR"
    else
        printf '\033[31madd your pub key to %s\033[0m\n' "$ADDR" >&2
        if [ "$ADDR" = "$ORCHESTRATOR_ADDR" ]; then
            no "ssh to orchestrator $ADDR (mandatory)"
        else
            no "ssh to $ADDR"
        fi
    fi
done

# ---- 1. the shipped config loads ---------------------------------------------
# Note: in `DIR=x STATE_DIR="$DIR/..." cmd`, later assignments see earlier ones,
# so use explicit paths here and match exactly those paths in the case pattern.
#out=$(LAB_CONFIG="$LAB_ROOT/config.env" LAB_ADVANCED="$LAB_ROOT/config.advanced.env" \
#      DIR="$TMP/ship" STATE_DIR="$TMP/ship/state" \
#      CLIENT_KEYS="$TMP/ship/clients" WORKER_KEYS="$TMP/ship/workers" \
#      "$BEAUT" init)
#case "$out" in *"state=$TMP/ship/state"*) ok "shipped config.env + advanced load" ;; *) no "shipped config load: $out" ;; esac
#
# ---- 2. client recognition ---------------------------------------------------
#out=$("$BEAUT" client add "$TMP/alice.pub" alice)
#case "$out" in added*) ok "client add" ;; *) no "client add: $out" ;; esac
#eq "client check known" "$("$BEAUT" client check "$TMP/alice.pub")" "ok"
#"$BEAUT" client check "$TMP/mallory.pub" >/dev/null 2>&1 && no "unknown key accepted" || ok "unknown key rejected"
#
#out=$(LAB_CLIENT_KEY="$TMP/mallory.pub" "$BEAUT" request --cpu 1 --mem 128 --disk 1 2>&1) \
#    && no "unauthorized request accepted" || ok "unauthorized request rejected"
#case "$out" in *"not in $CLIENT_KEYS"*) ok "unauthorized request explains why" ;; *) no "unauthorized message: $out" ;; esac
#
# ---- 3. worker keys ----------------------------------------------------------
#out=$("$BEAUT" worker add "$TMP/worker1.pub")
#case "$out" in *"permitlisten"*) ok "worker add prints reverse-forward line" ;; *) no "worker add: $out" ;; esac
#yes_ "orchestrator keys restrict reverse forwarding" \
#     "'$BEAUT' keys orchestrator | grep -q permitlisten"
#yes_ "worker keys restrict the client hop" \
#     "'$BEAUT' keys worker | grep -q 'permitopen=\"127.0.0.1:\*\"'"
#
# ---- 4. dispatch by heartbeat ------------------------------------------------
#"$BEAUT" heartbeat --name w-low --addr 10.0.0.1 --cpu-total 8 --cpu-free 8 \
#    --mem-free 8192 --disk-free 64 --port 22001 --priority 10 --term 1 >/dev/null
#"$BEAUT" heartbeat --name w-high --addr 10.0.0.2 --cpu-total 8 --cpu-free 8 \
#    --mem-free 8192 --disk-free 64 --port 22002 --priority 90 --term 1 >/dev/null
#
#out=$(LAB_CLIENT_KEY="$TMP/alice.pub" "$BEAUT" request --cpu 2 --mem 1024 --disk 8)
#id=${out%%$'\t'*}; ans=${out#*$'\t'}
#eq "request answered" "$(printf '%s' "$ans" | cut -f1)" "ok"
#eq "dispatch picks highest priority" "$(printf '%s' "$ans" | cut -f2)" "w-high"
#eq "answer stored" "$("$BEAUT" answer "$id" | cut -f2)" "w-high"
#
#out=$(LAB_CLIENT_KEY="$TMP/alice.pub" "$BEAUT" request --cpu 64 --mem 1024 --disk 8)
#eq "oversized request denied" "$(printf '%s' "${out#*$'\t'}" | cut -f1)" "denied"
#
# ---- 5. lease expiry terminates the command ----------------------------------
#rm -rf "$STATE_DIR"
#"$BEAUT" init >/dev/null
#"$BEAUT" heartbeat --name w-low --addr 10.0.0.1 --cpu-total 8 --cpu-free 8 \
#    --mem-free 8192 --disk-free 64 --port 22001 --priority 10 --term 1 >/dev/null
#out=$(LAB_CLIENT_KEY="$TMP/alice.pub" "$BEAUT" request --cpu 1 --mem 128 --disk 1)
#id=${out%%$'\t'*}
#sleep 4
#"$BEAUT" reap
#eq "expired lease terminates session" "$("$BEAUT" status | awk -v id="$id" '$1==id{print $NF}')" "terminated"
#[ -e "$STATE_DIR/kill/w-low/$id" ] && ok "kill tombstone queued for worker" || no "kill tombstone missing"
#
# ---- 6. stale heartbeat takes the worker down --------------------------------
#rm -rf "$STATE_DIR"
#"$BEAUT" init >/dev/null
#"$BEAUT" heartbeat --name w-low --addr 10.0.0.1 --cpu-total 8 --cpu-free 8 \
#    --mem-free 8192 --disk-free 64 --port 22001 --priority 10 --term 1 >/dev/null
#out=$(LAB_CLIENT_KEY="$TMP/alice.pub" "$BEAUT" request --cpu 1 --mem 128 --disk 1)
#id=${out%%$'\t'*}
#sleep 3
#"$BEAUT" reap
#eq "stale worker marked down" "$(awk -F'\t' '$1=="w-low"{print $11}' "$STATE_DIR/workers.tsv")" "down"
#eq "stale worker's session terminated" "$("$BEAUT" status | awk -v id="$id" '$1==id{print $NF}')" "terminated"
#
# ---- 7. local run, lease renewal, release ------------------------------------
#rm -rf "$STATE_DIR"
#"$BEAUT" init >/dev/null
#"$BEAUT" heartbeat --name testorch --addr 127.0.0.1 --cpu-total 4 --cpu-free 4 \
#    --mem-free 4096 --disk-free 32 --port 0 --priority 100 --term 1 >/dev/null
#out=$(LAB_CLIENT_KEY="$TMP/alice.pub" "$BEAUT" request --cpu 1 --mem 128 --disk 1)
#id=${out%%$'\t'*}
#run=$("$BEAUT" run "$id" -- sleep 30)
#pid=$(printf '%s' "$run" | cut -f3)
#kill -0 "$pid" 2>/dev/null && ok "command started under caps" || no "command not running"
#lease=$("$BEAUT" renew "$id" --seconds 30 | cut -f2)
#[ "$lease" -gt "$(date +%s)" ] && ok "lease renewed" || no "lease not renewed"
#"$BEAUT" release "$id" >/dev/null
#for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
#kill -0 "$pid" 2>/dev/null && no "released command still alive" || ok "released command killed"

# ---- summary -----------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
