#!/usr/bin/env bash
# tests/run.sh — smoke tests for the bash scaffold (no root, no network).
set -u   # no pipefail: checks deliberately pipe failing commands into grep
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
B="$ROOT/bin/beaut"
TMP="$(mktemp -d)"
HTTP_PID=""
cleanup() {
    [ -z "$HTTP_PID" ] || kill "$HTTP_PID" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export XDG_CONFIG_HOME="$TMP/home/.config" XDG_STATE_HOME="$TMP/home/.local/state"
unset "${!BEAUT_@}" 2>/dev/null
export BEAUT_STATE_DIR="$TMP/state"
# Hermetic: an empty config so that a developer's <repo>/config.env or a host's
# /etc/beaut/config.env can never leak into the "defaults" checks.
export BEAUT_CONFIG="$TMP/empty.env"; : > "$BEAUT_CONFIG"; chmod 600 "$BEAUT_CONFIG"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "== shellcheck"
if command -v shellcheck >/dev/null; then
    check "shellcheck clean" "shellcheck -x -P SCRIPTDIR '$B' '$ROOT'/lib/*.sh '$ROOT/install.sh' '$0'"
else
    echo "  skip (shellcheck not installed)"
fi

echo "== help / version / roles"
check "--help lists roles"        "$B --help | grep -q '^hub' && $B --help | grep -q '^worker' && $B --help | grep -q '^client'"
check "help exit 0"               "$B help"
check "version"                   "$B version | grep -q '^beaut '"
check "default role client"       "[ \"\$($B roles)\" = client ]"
check "--roles composable"        "[ \"\$($B --roles hub,worker,client roles)\" = 'hub worker client' ]"
check "--roles dedup/case"        "[ \"\$($B --roles Hub,hub,worker roles)\" = 'hub worker' ]"
check "bad role rejected"         "! $B --roles k8s roles"
check "unknown command rejected"  "! $B frobnicate"

echo "== role gating / not-implemented"
check "serve needs hub role"      "$B serve 2>&1 | grep -q 'not enabled'"
check "run without a client token fails clearly" "$B --roles client run true 2>&1 | grep -q 'client token'"
check "enroll needs worker role"  "$B enroll 50 2>&1 | grep -q 'not enabled'"
check "worker-exec runs"          "[ \"\$($B --roles worker worker-exec 1 128 1 -- echo hi)\" = hi ]"
$B daemon >/dev/null 2>&1; check "daemon exits 64 (no role service yet)" "[ $? -eq 64 ]"

echo "== config"
cat > "$TMP/c.env" <<EOF
DOMAIN="pool.example.org"
ROLES="hub,worker"
ADMIN_PORT=8888
STATE_DIR="$TMP/state2"
EOF
chmod 600 "$TMP/c.env"
check "-c loads config"           "$B -c '$TMP/c.env' config | grep -q 'DOMAIN=pool.example.org'"
check "config roles honoured"     "[ \"\$($B -c '$TMP/c.env' roles)\" = 'hub worker' ]"
check "env override BEAUT_DOMAIN" "BEAUT_DOMAIN=x.org $B -c '$TMP/c.env' config | grep -q 'DOMAIN=x.org'"
chmod 666 "$TMP/c.env"
check "world-writable config refused" "! $B -c '$TMP/c.env' roles"
chmod 600 "$TMP/c.env"
check "bad ADMIN_PORT refused"    "! BEAUT_ADMIN_PORT=99999 $B roles"
check "bad DOMAIN refused"        "! BEAUT_DOMAIN='a;b' $B roles"
check "bad TOKEN_TTL refused"     "! BEAUT_TOKEN_TTL_SECONDS=soon $B roles"
check "bad WORKER_STALE refused"  "! BEAUT_WORKER_STALE_SECONDS=0 $B roles && ! BEAUT_WORKER_STALE_SECONDS=soon $B roles"
check "bad WORKER_HEARTBEAT refused" "! BEAUT_WORKER_HEARTBEAT_SECONDS=0 $B roles && ! BEAUT_WORKER_HEARTBEAT_SECONDS=soon $B roles"
check "heartbeat must be below stale" "! BEAUT_WORKER_HEARTBEAT_SECONDS=90 BEAUT_WORKER_STALE_SECONDS=90 $B roles && BEAUT_WORKER_HEARTBEAT_SECONDS=30 BEAUT_WORKER_STALE_SECONDS=90 $B roles"
check "bad TUNNEL_PORT refused"   "! BEAUT_TUNNEL_PORT=0 $B roles"
check "bad TUNNEL_PORT_RANGE"     "! BEAUT_TUNNEL_PORT_RANGE=2000-1000 $B roles && ! BEAUT_TUNNEL_PORT_RANGE=abc $B roles"
check "bad TIERS refused"         "! BEAUT_TIERS='guest 1 2048 x' $B roles && ! BEAUT_TIERS='gold 1 1 1' $B roles"
check "relative STATE_DIR refused" "! BEAUT_STATE_DIR=rel/state $B roles"
check "BEAUT_PATH is not a config key" "BEAUT_PATH=/nowhere $B roles && [ -z \"\$(BEAUT_PATH=/nowhere $B config | grep '^PATH=')\" ]"
check "example config loads"      "cp '$ROOT/config.env.example' '$TMP/ex.env' && chmod 600 '$TMP/ex.env' && $B -c '$TMP/ex.env' config | grep -q 'ADMIN_PORT=8888'"
check "missing -c config fails"   "! $B -c '$TMP/nope.env' roles"
cp "$TMP/c.env" "$TMP/unreadable.env"; chmod 000 "$TMP/unreadable.env"
check "unreadable -c config fails (no silent defaults)" "! $B -c '$TMP/unreadable.env' roles && $B -c '$TMP/unreadable.env' roles 2>&1 | grep -q 'not readable'"
mkdir -p "$TMP/xdg/beaut"; cp "$TMP/c.env" "$TMP/xdg/beaut/config.env"; chmod 000 "$TMP/xdg/beaut/config.env"
# Exercise default lookup from a copied tool root so an optional developer
# config.env in the checkout cannot mask XDG behavior.
CONFIG_TEST_ROOT="$TMP/config-test-root"
mkdir -p "$CONFIG_TEST_ROOT"
cp -R "$ROOT/bin" "$ROOT/lib" "$CONFIG_TEST_ROOT/"
CONFIG_TEST_B="$CONFIG_TEST_ROOT/bin/beaut"
check "unreadable default-location config fails" "! env -u BEAUT_CONFIG XDG_CONFIG_HOME='$TMP/xdg' $CONFIG_TEST_B roles"
chmod 600 "$TMP/xdg/beaut/config.env"
check "readable default-location config used" "[ \"\$(env -u BEAUT_CONFIG XDG_CONFIG_HOME='$TMP/xdg' $CONFIG_TEST_B roles)\" = 'hub worker' ]"
cat > "$CONFIG_TEST_ROOT/config.env" <<EOF
ROLES="client"
STATE_DIR="$TMP/local-config-state"
EOF
chmod 600 "$CONFIG_TEST_ROOT/config.env"
check "repo-local config takes precedence over XDG" "[ \"\$(env -u BEAUT_CONFIG XDG_CONFIG_HOME='$TMP/xdg' $CONFIG_TEST_B roles)\" = client ]"
chmod 640 "$TMP/c.env"
check "0640 config accepted"      "$B -c '$TMP/c.env' roles"
chmod 660 "$TMP/c.env"
check "0660 config refused"       "! $B -c '$TMP/c.env' roles"
chmod 600 "$TMP/c.env"

echo "== tiers"
check "tier guest"                "[ \"\$($B tier guest)\" = '1 2048 16' ]"
check "tier registered"           "[ \"\$($B tier registered)\" = '4 4096 32' ]"
check "tier admin"                "[ \"\$($B tier admin)\" = '-1 -1 -1' ]"
check "tier unknown"              "! $B tier platinum"

echo "== scheduler"
SCHED_STATE="$TMP/sched"
SCHED_ENV="$TMP/sched.env"
cat > "$SCHED_ENV" <<EOF
STATE_DIR="$SCHED_STATE"
WORKER_STALE_SECONDS=90
ADMINS="boss@example.org"
EOF
chmod 600 "$SCHED_ENV"
export ROOT
SCHED_SH="$TMP/sched.sh"
cat > "$SCHED_SH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
. "$ROOT/lib/common.sh"
. "$ROOT/lib/auth.sh"
. "$ROOT/lib/hub.sh"
. "$ROOT/lib/client.sh"
. "$ROOT/lib/http.sh"
load_config
init_state
"$@"
EOF
sched() { BEAUT_CONFIG="$SCHED_ENV" BEAUT_STATE_DIR="$SCHED_STATE" bash "$SCHED_SH" "$@"; }

check "scheduler fixture users" "BEAUT_STATE_DIR='$SCHED_STATE' $B -c '$SCHED_ENV' status >/dev/null &&
    BEAUT_STATE_DIR='$SCHED_STATE' $B -c '$SCHED_ENV' user add guest@example.org >/dev/null &&
    BEAUT_STATE_DIR='$SCHED_STATE' $B -c '$SCHED_ENV' user add reg@example.org >/dev/null &&
    BEAUT_STATE_DIR='$SCHED_STATE' $B -c '$SCHED_ENV' user level reg@example.org registered >/dev/null &&
    BEAUT_STATE_DIR='$SCHED_STATE' $B -c '$SCHED_ENV' user add admin@example.org >/dev/null &&
    BEAUT_STATE_DIR='$SCHED_STATE' $B -c '$SCHED_ENV' user level admin@example.org admin >/dev/null"
check "ADMINS gets admin tier" "[ \"\$(sched user_tier boss@example.org)\" = admin ]"

NOW=$(date +%s)
printf 'w1\t21000\t50\t8\t8192\t64\t%s\talice\t/usr/local/bin/beaut\n' "$NOW" >> "$SCHED_STATE/workers.tsv"
printf 'w2\t21001\t50\t2\t2048\t16\t%s\tbob\t/opt/beaut\n' "$NOW" >> "$SCHED_STATE/workers.tsv"
printf 'wstale\t21002\t50\t64\t65536\t512\t1\told\tbeaut\n' >> "$SCHED_STATE/workers.tsv"

check "hub_pick fits guest" "sched hub_pick 1 2048 16 | cut -f1,2,6,7 |
    grep -qx \$'w1\t21000\talice\t/usr/local/bin/beaut'"
check "hub_pick registered fit" "sched hub_pick 4 4096 32 | cut -f1 | grep -qx w1"
check "hub_pick no fit"        "! sched hub_pick 100 1 1"
check "hub_pick ignores stale" "! sched hub_pick 64 65536 512"
check "hub_pick admin half"    "sched hub_pick -1 -1 -1 | cut -f1,3,4,5 |
    grep -qx \$'w1\t4\t4096\t32'"

EMPTY_STATE="$TMP/sched-empty"
cat > "$TMP/sched-empty.env" <<EOF
STATE_DIR="$EMPTY_STATE"
EOF
chmod 600 "$TMP/sched-empty.env"
BEAUT_STATE_DIR="$EMPTY_STATE" $B -c "$TMP/sched-empty.env" status >/dev/null 2>&1
check "hub_run no fit returns 4" "BEAUT_CONFIG='$TMP/sched-empty.env' BEAUT_STATE_DIR='$EMPTY_STATE' bash '$SCHED_SH' hub_run guest@example.org true; [ \$? -eq 4 ]"

mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/ssh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "${FAKE_SSH_LOG:?}"
code=${FAKE_SSH_EXIT:-0}
if [ -n "${FAKE_SSH_EXIT_FILE:-}" ] && [ -r "$FAKE_SSH_EXIT_FILE" ]; then
    code=$(cat "$FAKE_SSH_EXIT_FILE")
fi
exit "${code:-0}"
EOF
chmod +x "$TMP/fakebin/ssh"
cat > "$TMP/fakebin/curl" <<'EOF'
#!/bin/sh
hdr= body=
while [ $# -gt 0 ]; do
    case "$1" in
        -D) hdr=$2; shift 2 ;;
        -o) body=$2; shift 2 ;;
        *) shift ;;
    esac
done
printf 'HTTP/1.1 500 Internal Server Error\r\nX-Beaut-Exit: 42\r\n\r\n' > "$hdr"
printf 'boom\n' > "$body"
EOF
chmod +x "$TMP/fakebin/curl"
check "hub_run schedules and invokes ssh" "PATH='$TMP/fakebin:$PATH' FAKE_SSH_LOG='$TMP/ssh.log' sched hub_run guest@example.org echo hi &&
    grep -q 'alice@127.0.0.1 /usr/local/bin/beaut worker-exec 1 2048 16 -- echo hi' '$TMP/ssh.log'"
check "hub_run clears session" "[ ! -s '$SCHED_STATE/sessions.tsv' ]"
check "hub_run admin half"     "PATH='$TMP/fakebin:$PATH' FAKE_SSH_LOG='$TMP/ssh.log' sched hub_run admin@example.org echo hi &&
    grep -q 'worker-exec 4 4096 32 -- echo hi' '$TMP/ssh.log'"
check "hub_run ssh failure is 5" "PATH='$TMP/fakebin:$PATH' FAKE_SSH_EXIT=255 FAKE_SSH_LOG='$TMP/ssh.log' sched hub_run guest@example.org echo hi; [ \$? -eq 5 ]"
check "ssh failure clears session" "[ ! -s '$SCHED_STATE/sessions.tsv' ]"
check "client_run returns remote exit" "PATH='$TMP/fakebin:$PATH' CLIENT_TOKEN=0123456789abcdef0123456789abcdef sched client_run sh -c 'exit 42' >/dev/null; [ \$? -eq 42 ]"

echo "== state dir"
$B status >/dev/null 2>&1
check "state dir 0700"            "[ \"\$(stat -c %a '$TMP/state')\" = 700 ]"
check "state files 0600"          "[ \"\$(stat -c %a '$TMP/state/users.tsv')\" = 600 ]"
check "all state files exist"     "[ -f '$TMP/state/workers.tsv' ] && [ -f '$TMP/state/tokens.tsv' ] && [ -f '$TMP/state/sessions.tsv' ]"
check "explicit STATE_DIR unwritable → error, no silent fallback" "! BEAUT_STATE_DIR=/proc/nope $B status && BEAUT_STATE_DIR=/proc/nope $B status 2>&1 | grep -q 'not writable'"
check "default STATE_DIR unwritable → per-user fallback" "env -u BEAUT_STATE_DIR $B status 2>&1 | grep -q \"state_dir=$XDG_STATE_HOME/beaut\""

echo "== users"
check "user add"                  "$B user add Alice@Example.org"
check "user pending (lowercased)" "[ \"\$($B user pending)\" = alice@example.org ]"
check "user add existing refused"  "! $B user add alice@example.org && [ \"\$($B user pending)\" = alice@example.org ]"
check "user add invalid email"    "! $B user add not-an-email"
check "user add bad key"          "! $B user add bob@example.org 'ssh-rsa not a key'"
check "user approve"              "$B user approve alice@example.org && $B user list | grep -q $'alice@example.org\t\tregistered\t[1-9]'"
check "pending now empty"         "[ -z \"\$($B user pending)\" ]"
check "user level admin"          "$B user level alice@example.org admin && $B user list | grep -q $'\tadmin\t'"
check "user level invalid"        "! $B user level alice@example.org root"
check "user rm"                   "$B user rm alice@example.org && [ -z \"\$($B user list)\" ]"

echo "== ssh key helpers"
# shellcheck source=../lib/common.sh
. "$ROOT/lib/common.sh"; . "$ROOT/lib/auth.sh"; load_config; init_state
if command -v ssh-keygen >/dev/null; then
    ssh-keygen -q -t ed25519 -N '' -f "$TMP/k" >/dev/null 2>&1
    REAL="$(cat "$TMP/k.pub")"
    check "ssh_key_valid real key"    "ssh_key_valid '$REAL'"
    check "ssh_key_extract from mail" "printf 'hi\n\n  %s  \nbye\n' '$REAL' | ssh_key_extract | grep -q '^ssh-ed25519'"
    check "user add with key"         "$B user add carol@example.org '$REAL' && [ \"\$($B user list | cut -f2)\" = '$REAL' ]"
fi
check "ssh_key_valid rejects junk"    "! ssh_key_valid 'ssh-ed25519 \$(rm -rf /) x'"
check "ssh_key_extract none"          "! printf 'nothing here\n' | ssh_key_extract"

echo "== tokens"
T=$($B token issue dave@example.org)
check "token issue format"        "[[ '$T' =~ ^[a-f0-9]{32}$ ]]"
check "token check → owner"       "[ \"\$($B token check $T)\" = dave@example.org ]"
check "token burn → owner"        "[ \"\$($B token burn $T)\" = dave@example.org ]"
$B token check "$T" >/dev/null 2>&1; check "burnt token rejected (exit 2)" "[ $? -eq 2 ]"
check "burn twice fails"          "! $B token burn $T"
check "tampered token rejected"   "! $B token check ${T:0:31}0 && ! $B token check 'zz'"
check "token invalid email"       "! $B token issue nope"
check "expired token rejected"    "T2=\$(BEAUT_TOKEN_TTL_SECONDS=0 $B token issue e@example.org) && sleep 1 && ! BEAUT_TOKEN_TTL_SECONDS=0 $B token check \$T2"
check "tokens distinct"           "[ \"\$($B token issue f@example.org)\" != \"\$($B token issue f@example.org)\" ]"
CT0=$($B token client gina@example.org)
check "client token format"       "[[ '$CT0' =~ ^[a-f0-9]{32}$ ]]"
check "client token replaced"     "[ \"\$($B token client gina@example.org)\" != '$CT0' ]"

echo "== install.sh (--user, --no-service, into tmp prefix)"
check "install --user"            "XDG_CONFIG_HOME='$TMP/cfg' XDG_STATE_HOME='$TMP/st' '$ROOT/install.sh' --user --no-service --prefix '$TMP/prefix' --roles worker,client --domain pool.example.org"
check "installed beaut runs"      "BEAUT_CONFIG='$TMP/cfg/beaut/config.env' '$TMP/prefix/bin/beaut' roles | grep -q 'worker client'"
check "installed config 0600"     "[ \"\$(stat -c %a '$TMP/cfg/beaut/config.env')\" = 600 ]"
check "installed config domain"   "grep -q '^DOMAIN=\"pool.example.org\"' '$TMP/cfg/beaut/config.env'"
check "reinstall keeps config"    "echo '# keep' >> '$TMP/cfg/beaut/config.env' && XDG_CONFIG_HOME='$TMP/cfg' XDG_STATE_HOME='$TMP/st' '$ROOT/install.sh' --user --no-service --prefix '$TMP/prefix' && grep -q '# keep' '$TMP/cfg/beaut/config.env'"
check "uninstall"                 "XDG_CONFIG_HOME='$TMP/cfg' '$ROOT/install.sh' --user --no-service --prefix '$TMP/prefix' --uninstall && [ ! -e '$TMP/prefix/bin/beaut' ] && [ -e '$TMP/cfg/beaut/config.env' ]"
check "--domain injection refused" "! '$ROOT/install.sh' --user --no-service --prefix '$TMP/prefix2' --domain 'x\"; touch /tmp/pwned; #' && [ ! -e '$TMP/prefix2/bin/beaut' ]"

echo "== install.sh (system layout under unshare -r, redirected dirs)"
# unshare -r makes us uid 0 in a user namespace: the real system path runs
# (root-owned 0640 config, service-user dirs) without touching the host.
if command -v unshare >/dev/null && unshare -r true 2>/dev/null; then
    SYS="$TMP/sys"; mkdir -p "$SYS"
    sysinst() { env -u BEAUT_CONFIG -u BEAUT_STATE_DIR \
        BEAUT_INSTALL_CONF_DIR="$SYS/etc/beaut" BEAUT_INSTALL_STATE_DIR="$SYS/var/lib/beaut" \
        BEAUT_INSTALL_UNIT_DIR="$SYS/unit" BEAUT_INSTALL_USER=root \
        unshare -r "$ROOT/install.sh" --no-service --prefix "$SYS/usr" "$@"; }
    check "system install"           "sysinst --roles hub --domain pool.example.org"
    check "system config 0640"       "[ \"\$(stat -c %a '$SYS/etc/beaut/config.env')\" = 640 ] && [ \"\$(stat -c %a '$SYS/etc/beaut')\" = 750 ]"
    check "system config root-owned (uid 0 in ns)" "unshare -r stat -c %u '$SYS/etc/beaut/config.env' | grep -qx 0"
    check "system state 0700"        "[ \"\$(stat -c %a '$SYS/var/lib/beaut')\" = 700 ]"
    check "root loads system config" "[ \"\$(env -u BEAUT_STATE_DIR BEAUT_CONFIG='$SYS/etc/beaut/config.env' unshare -r '$SYS/usr/bin/beaut' roles)\" = hub ]"
    check "root status uses system state" "env -u BEAUT_STATE_DIR BEAUT_CONFIG='$SYS/etc/beaut/config.env' unshare -r '$SYS/usr/bin/beaut' status | grep -q 'state_dir=$SYS/var/lib/beaut'"
    check "system reinstall keeps config" "echo '# keep' >> '$SYS/etc/beaut/config.env' && sysinst --roles hub && grep -q '# keep' '$SYS/etc/beaut/config.env'"
    # On a real host a non-root admin cannot read the root:beaut 0640 config;
    # here ns-root is us, so emulate the unreadable file with chmod 000.
    chmod 000 "$SYS/etc/beaut/config.env"
    check "non-root admin: unreadable config fails, no split state" "! env -u BEAUT_STATE_DIR BEAUT_CONFIG='$SYS/etc/beaut/config.env' $B user pending"
    chmod 640 "$SYS/etc/beaut/config.env"
else
    echo "  skip (unshare -r unavailable)"
fi

echo "== http app (step 2)"
if ! command -v socat >/dev/null || ! command -v curl >/dev/null; then
    echo "  skip (socat/curl not installed)"
else
    pick_port() {
        local p
        for ((p = 20000; p <= 20200; p++)); do
            if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
                printf '%s\n' "$p"; return 0
            fi
        done
        return 1
    }
    HTTP_PORT=$(pick_port) || HTTP_PORT=""
    if [ -z "$HTTP_PORT" ]; then
        echo "  skip (no free port)"
    else
        HTTP_STATE="$TMP/http-state"
        env BEAUT_CONFIG="$TMP/empty.env" BEAUT_STATE_DIR="$HTTP_STATE" \
            BEAUT_ROLES=hub BEAUT_ADMIN_BIND=127.0.0.1 BEAUT_ADMIN_PORT="$HTTP_PORT" \
            BEAUT_TUNNEL_PORT_RANGE=21000-21099 \
            PATH="$TMP/fakebin:$PATH" FAKE_SSH_LOG="$TMP/http-ssh.log" \
            FAKE_SSH_EXIT_FILE="$TMP/http-ssh-exit" \
            "$B" serve >/dev/null 2>"$TMP/http.log" &
        HTTP_PID=$!
        ready=0
        for ((i = 0; i < 50; i++)); do
            if curl -fsS --noproxy '*' "http://127.0.0.1:$HTTP_PORT/health" >/dev/null 2>&1; then
                ready=1; break
            fi
            sleep 0.1
        done
        if [ "$ready" = 0 ]; then
            echo "  FAIL http server did not start"
            sed 's/^/    /' "$TMP/http.log" >&2
            fail=$((fail+1))
        else
            hget()    { curl -fsS --noproxy '*' "http://127.0.0.1:$HTTP_PORT$1"; }
            hstatus() { curl -sS --noproxy '*' -o "$TMP/hbody" -w '%{http_code}' \
                            "http://127.0.0.1:$HTTP_PORT$1"; }
            hpost()   { curl -sS --noproxy '*' -o "$TMP/hbody" -w '%{http_code}' \
                            -X POST --data-binary "$2" "http://127.0.0.1:$HTTP_PORT$1"; }

            check "health 200 ok"       "[ \"\$(hstatus /health)\" = 200 ] && [ \"\$(cat '$TMP/hbody')\" = ok ]"
            check "stats text"          "hget /stats | grep -q '^workers'"
            check "stats json empty"    "hget /stats.json | grep -q '\"workers\":{\"total\":0,\"active\":0,\"stale\":0}'"
            check "unknown path 404"    "[ \"\$(hstatus /nope)\" = 404 ]"
            check "POST / is 405"       "[ \"\$(hpost / '')\" = 405 ]"

            check "give50 script"       "hget /give50 | grep -q \"PCT='50'\""
            check "give50 valid sh"     "hget /give50 | sh -n"
            check "give0 clamps to 1"   "hget /give0 | grep -q \"PCT='1'\""
            check "give200 clamps to 100" "hget /give200 | grep -q \"PCT='100'\""
            check "giveabc rejected"    "[ \"\$(hstatus /giveabc)\" = 400 ]"
            check "give1000 rejected"   "[ \"\$(hstatus /give1000)\" = 400 ]"

            check "register form"       "[ \"\$(hpost /register 'name=w1&port=0&cpu_pct=50&cpu_total=8&mem_free_mib=8192&disk_free_gib=64')\" = 200 ]"
            check "worker row written"  "awk -F'\t' '\$1 == \"w1\" {n++} END {exit !(n == 1)}' '$HTTP_STATE/workers.tsv'"
            check "port auto-allocated" "awk -F'\t' '\$1 == \"w1\" && \$2 >= 21000 && \$2 <= 21099 {ok=1} END {exit !ok}' '$HTTP_STATE/workers.tsv'"
            check "stats sees worker"   "hget /stats.json | grep -q '\"workers\":{\"total\":1,\"active\":1,\"stale\":0}'"
            check "stats capacity"      "hget /stats.json | grep -q '\"cpu\":{\"total\":8,\"free\":8}'"

            check "register upsert"     "[ \"\$(hpost /register 'name=w1&port=22222&cpu_pct=25&cpu_total=4&mem_free_mib=4096&disk_free_gib=32')\" = 200 ] && [ \"\$(awk -F'\t' '\$1 == \"w1\" {n++} END {print n+0}' '$HTTP_STATE/workers.tsv')\" = 1 ]"
            check "register positional" "[ \"\$(hpost /register 'w2&0&50&2&2048&16')\" = 200 ]"
            hpost_enc() {
                local path=$1; shift
                local -a args=()
                while [ $# -gt 0 ]; do args+=(--data-urlencode "$1"); shift; done
                curl -sS --noproxy '*' -o "$TMP/hbody" -w '%{http_code}' \
                    -X POST "${args[@]}" "http://127.0.0.1:$HTTP_PORT$path"
            }
            if [ -n "${REAL:-}" ]; then
                KEYRC=$(hpost_enc /register name=wkey port=0 cpu_pct=50 cpu_total=2 \
                    mem_free_mib=2048 disk_free_gib=16 user=alice \
                    self=/usr/local/bin/beaut "pubkey=$REAL")
                check "register with key" "[ '$KEYRC' = 200 ]"
                check "tunnel key stored" "grep -q '^wkey' '$HTTP_STATE/tunnel_keys.tsv'"
                check "authorized-keys prints key" "BEAUT_CONFIG='$TMP/empty.env' BEAUT_STATE_DIR='$HTTP_STATE' BEAUT_ROLES=hub BEAUT_TUNNEL_USER=tunnel '$B' __authorized-keys tunnel x | grep -q '^ssh-ed25519'"
                # Enrollment is done with wkey; drop the row so the capacity
                # assertions below keep their simple arithmetic.
                awk -F'\t' '$1 != "wkey"' "$HTTP_STATE/workers.tsv" > "$TMP/w.tmp" &&
                    mv "$TMP/w.tmp" "$HTTP_STATE/workers.tsv"
            fi
            check "heartbeat" "[ \"\$(hpost /heartbeat 'name=w1')\" = 200 ]"
            check "heartbeat unknown" "[ \"\$(hpost /heartbeat 'name=nope')\" = 404 ]"
            check "hubkey is a key" "hget /hubkey | ssh-keygen -l -f /dev/stdin"
            check "run invalid token 403" "[ \"\$(hpost /run 'token=deadbeef&cmd=echo')\" = 403 ]"
            check "run needs cmd 400" "[ \"\$(hpost /run 'token=deadbeef')\" = 400 ]"
            check "register bad port"   "[ \"\$(hpost /register 'name=w3&port=99999&cpu_pct=50&cpu_total=2&mem_free_mib=2048&disk_free_gib=16')\" = 400 ]"
            check "register bad name"   "[ \"\$(hpost /register 'name=bad/name&port=0&cpu_pct=50&cpu_total=2&mem_free_mib=2048&disk_free_gib=16')\" = 400 ]"
            check "register bad pct"    "[ \"\$(hpost /register 'name=w3&port=0&cpu_pct=0&cpu_total=2&mem_free_mib=2048&disk_free_gib=16')\" = 400 ]"
            check "rejected rows absent" "awk -F'\t' '\$1 == \"w3\" {n++} END {exit !(n == 0)}' '$HTTP_STATE/workers.tsv'"
            check "oversized body 413"  "[ \"\$(curl -sS --noproxy '*' -o /dev/null -w '%{http_code}' -X POST -H 'Content-Length: 999999' --data-binary '' 'http://127.0.0.1:$HTTP_PORT/register')\" = 413 ]"
            check "chunked rejected"    "[ \"\$(curl -sS --noproxy '*' -o /dev/null -w '%{http_code}' -X POST -H 'Transfer-Encoding: chunked' --data-binary 'x' 'http://127.0.0.1:$HTTP_PORT/register')\" = 411 ]"

            BEAUT_STATE_DIR="$HTTP_STATE" "$B" user add eve@example.org >/dev/null
            BEAUT_STATE_DIR="$HTTP_STATE" "$B" user approve eve@example.org >/dev/null
            CT=$(BEAUT_STATE_DIR="$HTTP_STATE" "$B" token issue eve@example.org)
            check "client token 200"    "[ \"\$(hstatus /client/$CT)\" = 200 ]"
            check "client script email" "grep -q 'eve@example.org' '$TMP/hbody'"
            check "client script valid" "sh -n '$TMP/hbody'"
            RUNTOKEN=$(awk -F'\t' '$1 == "eve@example.org" {print $2}' "$HTTP_STATE/clients.tsv")
            check "client token embedded" "[ -n '$RUNTOKEN' ] && grep -q \"CLIENT_TOKEN=%s\" '$TMP/hbody'"
            check "token burned"        "[ \"\$(hstatus /client/$CT)\" = 410 ]"
            check "bad token 404"       "[ \"\$(hstatus /client/deadbeef)\" = 404 ]"

            check "run executes on worker" "[ \"\$(hpost /run \"token=$RUNTOKEN&cmd=echo%20hi\")\" = 200 ] &&
                [ -z \"\$(cat '$TMP/hbody')\" ] &&
                grep -q 'beaut worker-exec 4 4096 32 -- bash -c echo hi' '$TMP/http-ssh.log'"
            check "run remote failure is 500" "echo 42 > '$TMP/http-ssh-exit' &&
                [ \"\$(hpost /run \"token=$RUNTOKEN&cmd=false\")\" = 500 ]"
            check "run remote failure carries exit" "echo 42 > '$TMP/http-ssh-exit' &&
                curl -sS --noproxy '*' -D '$TMP/hhdr' -o '$TMP/hbody' -X POST \
                    --data-binary \"token=$RUNTOKEN&cmd=false\" \
                    'http://127.0.0.1:$HTTP_PORT/run' &&
                grep -qi '^X-Beaut-Exit: 42' '$TMP/hhdr'"
            rm -f "$TMP/http-ssh-exit"
            check "run clears session"  "[ ! -s '$HTTP_STATE/sessions.tsv' ]"

            printf 's1\teve@example.org\tw1\tcmd\t1\t512\t4\t%s\n' "$(date +%s)" >> "$HTTP_STATE/sessions.tsv"
            check "stats sessions"      "hget /stats.json | grep -q '\"sessions\":{\"active\":1}'"
            check "stats cpu free"      "hget /stats.json | grep -q '\"cpu\":{\"total\":6,\"free\":5}'"
            check "stats mem free"      "hget /stats.json | grep -q '\"memory_mib\":{\"total\":6144,\"free\":5632}'"
            check "stats disk free"     "hget /stats.json | grep -q '\"disk_gib\":{\"total\":48,\"free\":44}'"

            printf 'w3\t20001\t50\t2\t2048\t16\t1\n' >> "$HTTP_STATE/workers.tsv"
            check "stale worker counted" "hget /stats.json | grep -q '\"workers\":{\"total\":3,\"active\":2,\"stale\":1}'"
            check "stale capacity ignored" "hget /stats.json | grep -q '\"cpu\":{\"total\":6,\"free\":5}'"

            BEAUT_STATE_DIR="$HTTP_STATE" "$B" user add pending@example.org >/dev/null 2>&1
            check "stats pending"       "hget /stats.json | grep -q '\"pending_users\":1'"

            check "bundle is gzip"      "hget /beaut.tar.gz | gzip -t"
            check "bundle has beaut"    "hget /beaut.tar.gz | tar -tzf - | grep -qx 'bin/beaut'"
        fi
        kill "$HTTP_PID" 2>/dev/null || true
        wait "$HTTP_PID" 2>/dev/null || true
        HTTP_PID=""
    fi
fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
