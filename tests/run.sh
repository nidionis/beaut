#!/usr/bin/env bash
# tests/run.sh — smoke tests for the bash scaffold (no root, no network).
set -u   # no pipefail: checks deliberately pipe failing commands into grep
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
B="$ROOT/bin/beaut"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
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
    check "shellcheck clean" "shellcheck -x '$B' '$ROOT'/lib/*.sh '$ROOT/install.sh' '$0'"
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
$B --roles hub serve >/dev/null 2>&1; check "serve exits 64 when planned" "[ $? -eq 64 ]"
$B --roles client run true >/dev/null 2>&1; check "run exits 64 when planned" "[ $? -eq 64 ]"
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

echo "== state dir"
$B status >/dev/null 2>&1
check "state dir 0700"            "[ \"\$(stat -c %a '$TMP/state')\" = 700 ]"
check "state files 0600"          "[ \"\$(stat -c %a '$TMP/state/users.tsv')\" = 600 ]"
check "all state files exist"     "[ -f '$TMP/state/workers.tsv' ] && [ -f '$TMP/state/tokens.tsv' ] && [ -f '$TMP/state/sessions.tsv' ]"
check "explicit STATE_DIR unwritable → error, no silent fallback" "! BEAUT_STATE_DIR=/proc/nope $B status && BEAUT_STATE_DIR=/proc/nope $B status 2>&1 | grep -q 'not writable'"
check "default STATE_DIR unwritable → per-user fallback" "env -u BEAUT_STATE_DIR $B status 2>&1 | grep -q \"state_dir=$XDG_STATE_HOME/beaut\""

echo "== users"
KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGxQjqpBJdx+Q0a1D3yq0xn9D2gVq1Ggk1OtAq0q1q0q test@x"
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

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
