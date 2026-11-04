#!/usr/bin/env bash
# lab/lib/lab.sh — config, state and auth helpers for the beaut lab prototype.
# Sourced, never executed. Bash only, no root, no network required.

[ -n "${LAB_LIB_LOADED:-}" ] && return 0
LAB_LIB_LOADED=1

LAB_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# ---- logging -----------------------------------------------------------------
lab_log()  { printf '%s lab[%s] %s\n' "$(date -u +%FT%TZ)" "${NAME:-lab}" "$*" >&2; }
lab_warn() { lab_log "warn: $*"; }
lab_die()  { lab_log "error: $*"; exit "${LAB_EXIT:-1}"; }

have() { command -v "$1" >/dev/null 2>&1; }
now()  { date +%s; }

is_uint() { [[ ${1:-} =~ ^[0-9]+$ ]]; }
is_num()  { [[ ${1:-} =~ ^[0-9]+([.][0-9]+)?$ ]]; }
is_port() { is_uint "$1" && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

# ---- config ------------------------------------------------------------------
# Source config.env, then its `.advanced.env` sibling (same directory, same
# stem), then fill defaults. Environment wins over the file for DIR, STATE_DIR,
# CLIENT_KEYS and WORKER_KEYS so tests can run hermetically.
load_config() {
    local cfg="${LAB_CONFIG:-$LAB_ROOT/config.env}"
    [ -r "$cfg" ] || lab_die "config $cfg is not readable"
    # shellcheck disable=SC1090
    . "$cfg"

    local adv="${LAB_ADVANCED:-${cfg%.env}.advanced.env}"
    if [ -n "$adv" ] && [ -e "$adv" ]; then
        [ -r "$adv" ] || lab_die "advanced config $adv is not readable"
        # shellcheck disable=SC1090
        . "$adv"
    fi

    NAME=${NAME:-$(hostname -s 2>/dev/null || echo beaut)}
    DIR=${DIR:-$HOME/.$NAME}
    CLIENT_KEYS=${CLIENT_KEYS:-$DIR/clients}
    WORKER_KEYS=${WORKER_KEYS:-$DIR/workers}
    STATE_DIR=${STATE_DIR:-$DIR/state}
    ORCHESTRATOR_NAME=${ORCHESTRATOR_NAME:-$NAME}
    ORCHESTRATOR_ADDR=${ORCHESTRATOR_ADDR:-127.0.0.1}
    ORCHESTRATOR_PRIORITY=${ORCHESTRATOR_PRIORITY:-100}
    ADMIN_PORT=${ADMIN_PORT:-8888}
    TUNNEL_PORT=${TUNNEL_PORT:-22}
    TUNNEL_PORT_RANGE=${TUNNEL_PORT_RANGE:-22000-22099}
    WORKER_STALE_SECONDS=${WORKER_STALE_SECONDS:-90}
    SESSION_LEASE_SECONDS=${SESSION_LEASE_SECONDS:-60}
    KILL_GRACE_SECONDS=${KILL_GRACE_SECONDS:-5}
    DISPATCH_POLICY=${DISPATCH_POLICY:-priority}
    GIVE_PCT=${GIVE_PCT:-50}
    LOG_LEVEL=${LOG_LEVEL:-info}
    TIERS=${TIERS:-$'guest 1 2048 16\nregistered 4 4096 32\nadmin -1 -1 -1'}
    EXEC_CPU_QUOTA=${EXEC_CPU_QUOTA:-50%}
    EXEC_MEMORY_MAX=${EXEC_MEMORY_MAX:-512M}
    EXEC_IO_WEIGHT=${EXEC_IO_WEIGHT:-10}
    EXEC_NICE=${EXEC_NICE:-19}
    EXEC_IONICE_CLASS=${EXEC_IONICE_CLASS:-3}
    EXEC_ULIMIT_V_KB=${EXEC_ULIMIT_V_KB:-524288}

    case "$STATE_DIR" in /*) ;; *) lab_die "STATE_DIR must be absolute (got '$STATE_DIR')" ;; esac
    case "$CLIENT_KEYS" in /*) ;; *) lab_die "CLIENT_KEYS must be absolute (got '$CLIENT_KEYS')" ;; esac
    case "$WORKER_KEYS" in /*) ;; *) lab_die "WORKER_KEYS must be absolute (got '$WORKER_KEYS')" ;; esac
    is_port "$ADMIN_PORT" || lab_die "ADMIN_PORT must be 1..65535"
    is_port "$TUNNEL_PORT" || lab_die "TUNNEL_PORT must be 1..65535"
    [[ "$TUNNEL_PORT_RANGE" =~ ^[0-9]+-[0-9]+$ ]] || lab_die "TUNNEL_PORT_RANGE must be LOW-HIGH"
    is_uint "$WORKER_STALE_SECONDS" && [ "$WORKER_STALE_SECONDS" -ge 1 ] \
        || lab_die "WORKER_STALE_SECONDS must be a positive integer"
    is_uint "$SESSION_LEASE_SECONDS" && [ "$SESSION_LEASE_SECONDS" -ge 1 ] \
        || lab_die "SESSION_LEASE_SECONDS must be a positive integer"
    is_uint "$KILL_GRACE_SECONDS" || lab_die "KILL_GRACE_SECONDS must be a non-negative integer"
    is_uint "$GIVE_PCT" && [ "$GIVE_PCT" -ge 1 ] && [ "$GIVE_PCT" -le 100 ] \
        || lab_die "GIVE_PCT must be 1..100"
    case "$LOG_LEVEL" in debug|info|warn|error) ;; *) lab_die "LOG_LEVEL must be debug|info|warn|error" ;; esac
}

# ---- state -------------------------------------------------------------------
# $STATE_DIR/workers.tsv   name addr cpu_total cpu_free mem_free disk_free port priority last_seen term status
# $STATE_DIR/sessions.tsv  id client worker cmd cpu mem disk pid started lease_until term status
# $STATE_DIR/requests/     <id>.req (request) and <id>.ans (dispatch answer)
# $STATE_DIR/kill/<worker>/<id>  pending termination (pid, ts, reason)
state_init() {
    mkdir -p "$STATE_DIR/requests" "$STATE_DIR/kill" "$STATE_DIR/logs" \
             "$(dirname "$CLIENT_KEYS")" "$(dirname "$WORKER_KEYS")" \
        || lab_die "cannot create state under $STATE_DIR"
    chmod 700 "$DIR" "$STATE_DIR" 2>/dev/null || true
    local f
    for f in "$STATE_DIR/workers.tsv" "$STATE_DIR/sessions.tsv"; do
        [ -e "$f" ] || : > "$f"
        chmod 600 "$f" 2>/dev/null || true
    done
    for f in "$CLIENT_KEYS" "$WORKER_KEYS"; do
        [ -e "$f" ] || : > "$f"
        chmod 600 "$f" 2>/dev/null || true
    done
}

event() {
    printf '%s\t%s\t%s\n' "$(now)" "${NAME:-lab}" "$*" >> "$STATE_DIR/logs/events.log"
}

with_lock() {
    local f=$1; shift
    if have flock; then
        ( flock -w 10 9 || { echo "lock timeout on $f" >&2; exit 1; }; "$@" ) 9>"$f.lock"
    else
        "$@"
    fi
}

# tsv_append <file> field... — tabs/newlines in fields are stripped
tsv_append() {
    local f=$1; shift
    local row="" x
    for x in "$@"; do x=${x//$'\t'/ }; x=${x//$'\n'/ }; row="$row${row:+$'\t'}$x"; done
    printf '%s\n' "$row" >> "$f"
}

tsv_delete() {
    local f=$1 tmp
    tmp=$(mktemp "$f.XXXXXX") || return 1
    awk -F'\t' -v c="$2" -v v="$3" '$c != v' "$f" > "$tmp" \
        && chmod 600 "$tmp" && mv -f "$tmp" "$f"
}

# ---- workers -----------------------------------------------------------------
workers_file() { printf '%s/workers.tsv\n' "$STATE_DIR"; }

worker_get() {
    awk -F'\t' -v n="$1" -v c="$2" '$1 == n { print $c; exit }' "$(workers_file)"
}
worker_term()   { worker_get "$1" 10; }
worker_status() { worker_get "$1" 11; }

# worker_upsert name addr cpu_total cpu_free mem_free disk_free port priority last_seen term status
worker_upsert() {
    local f tmp
    f=$(workers_file); tmp=$(mktemp "$f.XXXXXX") || return 1
    awk -F'\t' -v OFS='\t' \
        -v n="$1" -v a="$2" -v ct="$3" -v cf="$4" -v mm="$5" -v dd="$6" \
        -v po="$7" -v pr="$8" -v se="$9" -v te="${10}" -v st="${11}" '
        $1 == n { print n,a,ct,cf,mm,dd,po,pr,se,te,st; done=1; next }
        { print }
        END { if (!done) print n,a,ct,cf,mm,dd,po,pr,se,te,st }
    ' "$f" > "$tmp"
    chmod 600 "$tmp" && mv -f "$tmp" "$f"
}

# CPU/mem/disk already committed to pending/running sessions on a worker.
worker_reserved() {
    awk -F'\t' -v w="$1" '
        $3 == w && ($12 == "pending" || $12 == "running") { c += $5; m += $6; d += $7 }
        END { printf "%.2f\t%d\t%d\n", c, m, d }
    ' "$STATE_DIR/sessions.tsv"
}

# Pick the best live worker that fits cpu/mem/disk.
# Output: name<TAB>addr<TAB>port<TAB>term<TAB>free_cpu<TAB>free_mem<TAB>free_disk
pick_worker() {
    local want_cpu=$1 want_mem=$2 want_disk=$3 ts
    ts=$(now)
    local n a ct cf mm dd po pr se te st rc rm rd ac am ad
    local best="" best_prio=-1 best_mem=-1 line=""
    while IFS=$'\t' read -r n a ct cf mm dd po pr se te st; do
        [ -n "$n" ] || continue
        [ "$st" = "up" ] || continue
        is_uint "$se" || continue
        [ $((ts - se)) -le "$WORKER_STALE_SECONDS" ] || continue
        IFS=$'\t' read -r rc rm rd < <(worker_reserved "$n")
        ac=$(awk -v x="$cf" -v y="$rc" 'BEGIN { printf "%.2f", x - y }')
        am=$((mm - rm)); ad=$((dd - rd))
        awk -v a="$ac" -v m="$am" -v d="$ad" -v wc="$want_cpu" -v wm="$want_mem" -v wd="$want_disk" \
            'BEGIN { exit !(a >= wc && m >= wm && d >= wd) }' || continue
        if [ "$pr" -gt "$best_prio" ] || { [ "$pr" -eq "$best_prio" ] && [ "$am" -gt "$best_mem" ]; }; then
            best=$n; best_prio=$pr; best_mem=$am
            line="$n"$'\t'"$a"$'\t'"$po"$'\t'"$te"$'\t'"$ac"$'\t'"$am"$'\t'"$ad"
        fi
    done < "$(workers_file)"
    [ -n "$best" ] && printf '%s\n' "$line"
    return 0
}

# ---- sessions ----------------------------------------------------------------
session_get() {
    awk -F'\t' -v id="$1" -v c="$2" '$1 == id { print $c; exit }' "$STATE_DIR/sessions.tsv"
}

session_set() {
    local f tmp
    f="$STATE_DIR/sessions.tsv"; tmp=$(mktemp "$f.XXXXXX") || return 1
    awk -F'\t' -v OFS='\t' -v id="$1" -v c="$2" -v v="$3" '$1 == id { $c = v } { print }' "$f" > "$tmp"
    chmod 600 "$tmp" && mv -f "$tmp" "$f"
}

# session_add id client worker cmd cpu mem disk pid started lease term status
session_add() {
    with_lock "$STATE_DIR/sessions.tsv" tsv_append "$STATE_DIR/sessions.tsv" "$@"
}

session_active_ids() {
    awk -F'\t' -v w="$1" '$3 == w && ($12 == "pending" || $12 == "running") { print $1 }' \
        "$STATE_DIR/sessions.tsv"
}

# ---- keys / auth -------------------------------------------------------------
# Extract "type base64" from a key line that may carry options or a comment.
key_material() {
    awk '{
        for (i = 1; i <= NF; i++)
            if ($i ~ /^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp[0-9]+|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh.com)$/) {
                print $i " " $(i + 1); exit
            }
    }'
}

# stdin: one key line -> fingerprint (or "type base64" without ssh-keygen)
key_fp() {
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/lab-key.XXXXXX") || return 1
    key_material > "$tmp"
    if [ ! -s "$tmp" ]; then rm -f "$tmp"; return 1; fi
    if have ssh-keygen; then
        ssh-keygen -lf "$tmp" 2>/dev/null | awk '{ print $2 }'
    else
        awk '{ print $1 " " $2 }' "$tmp"
    fi
    rm -f "$tmp"
}

resolve_key() {
    if [ -f "$1" ]; then cat "$1"; else printf '%s\n' "$1"; fi
}

# authorized_keys_has <key-line-or-file> <authorized_keys-file>
authorized_keys_has() {
    local keyline file fp line lfp
    keyline=$(resolve_key "$1"); file=$2
    [ -r "$file" ] || return 1
    fp=$(printf '%s\n' "$keyline" | key_fp)
    [ -n "$fp" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        lfp=$(printf '%s\n' "$line" | key_fp)
        [ "$lfp" = "$fp" ] && return 0
    done < "$file"
    return 1
}

# Sets CLIENT_ID (fingerprint) and CLIENT_NAME (comment, if any).
auth_client() {
    local key fp
    key=$(resolve_key "${1:-${LAB_CLIENT_KEY:-}}")
    [ -n "$key" ] || lab_die "no client key (use --key, LAB_CLIENT_KEY, or an SSH forced command)"
    authorized_keys_has "$key" "$CLIENT_KEYS" \
        || lab_die "client key is not in $CLIENT_KEYS"
    fp=$(printf '%s\n' "$key" | key_fp)
    CLIENT_ID=${LAB_CLIENT_NAME:-$fp}
    CLIENT_NAME=$(printf '%s\n' "$key" | awk '{ print $NF }')
    case "$CLIENT_NAME" in ssh-*|ecdsa-*|sk-*) CLIENT_NAME=$CLIENT_ID ;; esac
}

auth_worker() {
    local key
    key=$(resolve_key "${1:-${LAB_WORKER_KEY:-}}")
    [ -n "$key" ] || lab_die "no worker key (use --key or LAB_WORKER_KEY)"
    authorized_keys_has "$key" "$WORKER_KEYS" \
        || lab_die "worker key is not in $WORKER_KEYS"
}

# ---- termination -------------------------------------------------------------
# A session is killed when its lease expires or its worker goes stale. The
# orchestrator writes a tombstone to kill/<worker>/<id>; the worker (or the
# orchestrator itself when it hosts that worker) drains it: TERM, grace, KILL.
terminate_session() {
    local id=$1 reason=$2 pid worker ts
    pid=$(session_get "$id" 8)
    worker=$(session_get "$id" 3)
    [ -n "$worker" ] || return 0
    session_set "$id" 12 terminated
    ts=$(now)
    mkdir -p "$STATE_DIR/kill/$worker"
    printf '%s\t%s\t%s\n' "${pid:-0}" "$ts" "$reason" > "$STATE_DIR/kill/$worker/$id"
    event "terminate $id worker=$worker pid=${pid:-0} reason=$reason"
    [ "$worker" = "$NAME" ] && reap_local
    return 0
}

reap_local() {
    local dir="$STATE_DIR/kill/$NAME" f pid ts reason t
    [ -d "$dir" ] || return 0
    for f in "$dir"/*; do
        [ -e "$f" ] || continue
        IFS=$'\t' read -r pid ts reason < "$f" || true
        if [ -n "${pid:-}" ] && [ "$pid" != "0" ] && kill -0 "$pid" 2>/dev/null; then
            t=$(now)
            if [ -e "$f.term" ]; then
                if [ $((t - ts)) -ge "$KILL_GRACE_SECONDS" ]; then
                    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
                    rm -f "$f" "$f.term"
                    event "killed $pid (SIGKILL) reason=$reason"
                fi
            else
                kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
                : > "$f.term"
                event "killed $pid (SIGTERM) reason=$reason"
            fi
        else
            rm -f "$f" "$f.term"
        fi
    done
}

# reap: worker liveness first (heartbeat), then per-session leases.
cmd_reap() {
    state_init
    local ts n a ct cf mm dd po pr se te st id client w cmd cpu mem disk pid started lease term status
    ts=$(now)

    while IFS=$'\t' read -r n a ct cf mm dd po pr se te st; do
        [ -n "$n" ] || continue
        [ "$st" = "up" ] || continue
        is_uint "$se" || continue
        if [ $((ts - se)) -gt "$WORKER_STALE_SECONDS" ]; then
            worker_upsert "$n" "$a" "$ct" "$cf" "$mm" "$dd" "$po" "$pr" "$se" "$te" "down"
            event "worker $n down after $((ts - se))s without heartbeat"
            for id in $(session_active_ids "$n"); do
                terminate_session "$id" worker-stale
            done
        fi
    done < "$(workers_file)"

    while IFS=$'\t' read -r id client w cmd cpu mem disk pid started lease term status; do
        [ -n "$id" ] || continue
        case "$status" in pending|running) ;; *) continue ;; esac
        if [ "$lease" -gt 0 ] && [ "$ts" -gt "$lease" ]; then
            terminate_session "$id" lease-expired
        fi
    done < "$STATE_DIR/sessions.tsv"

    reap_local
    event "reap done"
}
