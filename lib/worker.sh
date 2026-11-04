#!/usr/bin/env bash
# lib/worker.sh — enrollment, reverse tunnel and quota-limited execution. Sourced.
# shellcheck shell=bash
#
# A worker donates N% of its CPU/RAM/free disk, registers with the hub over
# HTTP, keeps a reverse SSH tunnel to the hub's TUNNEL_USER, and runs incoming
# commands through `worker-exec` (systemd-run --user scope when available).

[ -n "${BEAUT_WORKER_LOADED:-}" ] && return 0
BEAUT_WORKER_LOADED=1

# ---- identity / state -------------------------------------------------------
worker_service_user() {
    if [ "$(id -u)" = 0 ]; then
        id -u "$WORKER_USER" >/dev/null 2>&1 \
            || die "worker user '$WORKER_USER' does not exist; run install.sh first"
        printf '%s\n' "$WORKER_USER"
    else
        id -un
    fi
}
worker_svc_home() {
    local u=$1 h
    h=$(getent passwd "$u" 2>/dev/null | cut -d: -f6)
    [ -n "$h" ] || h=${HOME:-/}
    printf '%s\n' "$h"
}
worker_key_dir() { printf '%s\n' "${WORKER_KEY_DIR:-$STATE_DIR/worker}"; }
worker_state_file() { printf '%s/state.env\n' "$(worker_key_dir)"; }
worker_private_key() { printf '%s/id_ed25519\n' "$(worker_key_dir)"; }
worker_enrolled() {
    [ -s "$(worker_state_file)" ] && [ -s "$(worker_private_key)" ]
}

# worker_caps <pct> — fill WC_PCT/WC_CPU/WC_MEM/WC_DISK from this host.
worker_caps() {
    local pct=$1 dir=${2:-/} cpus mem disk
    cpus=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
    mem=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null)
    [ -n "$mem" ] || mem=1024
    disk=$(df -Pk "$dir" 2>/dev/null | awk 'NR == 2 {print int($4 / 1024 / 1024)}')
    [ -n "$disk" ] || disk=16
    WC_PCT=$pct
    WC_CPU=$(( cpus * pct / 100 )); [ "$WC_CPU" -ge 1 ] || WC_CPU=1
    WC_MEM=$(( mem * pct / 100 ));  [ "$WC_MEM" -ge 1 ] || WC_MEM=1
    WC_DISK=$(( disk * pct / 100 )); [ "$WC_DISK" -ge 1 ] || WC_DISK=1
}

# ---- ssh keys ---------------------------------------------------------------
worker_ensure_key() {
    local dir key user
    dir=$(worker_key_dir); key=$(worker_private_key)
    user=$(worker_service_user)
    mkdir -p "$dir"; chmod 700 "$dir"
    if [ ! -s "$key" ]; then
        ssh-keygen -q -t ed25519 -N '' -C "beaut-worker@${NAME:-$(hostname -s 2>/dev/null || echo worker)}" -f "$key" >/dev/null
        chmod 600 "$key"; chmod 644 "$key.pub"
    fi
    if [ "$(id -u)" = 0 ]; then
        chown -R "$user:$(id -gn "$user" 2>/dev/null || echo "$user")" "$dir"
    fi
}

# worker_authorize_hub <pubkey> — let the hub log in as the worker user.
worker_authorize_hub() {
    local pub=$1 user home sshdir auth
    user=$(worker_service_user)
    home=$(worker_svc_home "$user")
    sshdir="$home/.ssh"; auth="$sshdir/authorized_keys"
    mkdir -p "$sshdir"; chmod 700 "$sshdir"
    touch "$auth"; chmod 600 "$auth"
    if ! grep -qxF "no-pty,no-agent-forwarding,no-X11-forwarding $pub" "$auth"; then
        printf 'no-pty,no-agent-forwarding,no-X11-forwarding %s\n' "$pub" >> "$auth"
    fi
    if [ "$(id -u)" = 0 ]; then
        chown -R "$user:$(id -gn "$user" 2>/dev/null || echo "$user")" "$sshdir"
    fi
}

# ---- registration -----------------------------------------------------------
worker_register() {
    local base pub user self resp port
    base=$(hub_url)
    pub=$(cat "$(worker_private_key).pub")
    user=$(worker_service_user)
    self=${BEAUT_SELF:-beaut}
    need curl
    resp=$(curl -fsS --noproxy '*' -X POST \
        --data-urlencode "name=$NAME" \
        --data-urlencode "port=0" \
        --data-urlencode "cpu_pct=$WC_PCT" \
        --data-urlencode "cpu_total=$WC_CPU" \
        --data-urlencode "mem_free_mib=$WC_MEM" \
        --data-urlencode "disk_free_gib=$WC_DISK" \
        --data-urlencode "user=$user" \
        --data-urlencode "self=$self" \
        --data-urlencode "pubkey=$pub" \
        "$base/register") || die "registration with $base failed"
    case "$resp" in
        ok\ port=*) port=${resp#ok port=} ;;
        *) die "unexpected registration reply: $resp" ;;
    esac
    is_port "$port" || die "hub returned an invalid tunnel port: $port"
    printf '%s\n' "$port"
}

# ---- enroll -----------------------------------------------------------------
# worker_enroll [pct] [hub_pubkey] — register and start the reverse tunnel.
worker_enroll() {
    local pct=${1:-$GIVE_PCT} hubpub=${2:-} user home base port state key
    is_uint "$pct" && [ "$pct" -ge 1 ] && [ "$pct" -le 100 ] \
        || die "donation percentage must be 1..100 (got '$pct')"
    need ssh ssh-keygen
    init_state
    user=$(worker_service_user)
    home=$(worker_svc_home "$user")
    base=$(hub_url)

    worker_caps "$pct" "$home"
    worker_ensure_key

    if [ -z "$hubpub" ]; then
        need curl
        hubpub=$(curl -fsS --noproxy '*' "$base/hubkey") \
            || die "cannot fetch the hub key from $base/hubkey"
    fi
    ssh_key_valid "$hubpub" || die "hub returned an invalid ssh public key"
    worker_authorize_hub "$hubpub"

    port=$(worker_register)
    state=$(worker_state_file)
    {
        printf 'WORKER_NAME=%q\n' "$NAME"
        printf 'WORKER_PORT=%q\n' "$port"
        printf 'WORKER_USER=%q\n' "$user"
        printf 'HUB_URL=%q\n' "$base"
        printf 'HUB_HOST=%q\n' "$DOMAIN"
        printf 'TUNNEL_USER=%q\n' "$TUNNEL_USER"
        printf 'TUNNEL_PORT=%q\n' "$TUNNEL_PORT"
        printf 'WORKER_SSH_PORT=%q\n' "$WORKER_SSH_PORT"
        printf 'WORKER_KEY=%q\n' "$(worker_private_key)"
    } > "$state"
    chmod 600 "$state"
    [ "$(id -u)" = 0 ] && chown "$user:$(id -gn "$user" 2>/dev/null || echo "$user")" "$state"

    info "enrolled $NAME: port=$port cpu=$WC_CPU mem=${WC_MEM}MiB disk=${WC_DISK}GiB"
    worker_restart_service
}

# ---- daemon -----------------------------------------------------------------
worker_tunnel() {
    local key known host port
    key=$WORKER_KEY; known="$(dirname "$key")/known_hosts"
    host=${HUB_HOST:-$DOMAIN}; port=$TUNNEL_PORT
    local -a cmd
    if have autossh; then
        cmd=(autossh -M 0 -N)
    else
        cmd=(ssh -N)
    fi
    cmd+=(-o BatchMode=yes -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes
          -o ServerAliveInterval=30 -o ServerAliveCountMax=3
          -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile="$known" -i "$key" -p "$port"
          -R "$WORKER_PORT:localhost:$WORKER_SSH_PORT"
          "$TUNNEL_USER@$host")
    info "tunnel $WORKER_PORT -> $TUNNEL_USER@$host:$port (local sshd $WORKER_SSH_PORT)"
    exec "${cmd[@]}"
}

worker_heartbeat() {
    need curl
    curl -fsS --noproxy '*' -X POST --data-urlencode "name=$WORKER_NAME" \
        "$HUB_URL/heartbeat" >/dev/null 2>&1 || debug "heartbeat failed"
}

worker_daemon() {
    local state
    state=$(worker_state_file)
    if [ ! -s "$state" ]; then
        warn "worker not enrolled; run 'beaut enroll <pct>'"
        return 64
    fi
    # shellcheck disable=SC1090
    . "$state"
    [ -s "$WORKER_KEY" ] || { warn "worker key missing: $WORKER_KEY"; return 64; }
    local tpid rc=0
    worker_tunnel &
    tpid=$!
    trap 'kill "$tpid" 2>/dev/null || true' EXIT INT TERM
    worker_heartbeat
    while kill -0 "$tpid" 2>/dev/null; do
        sleep "${WORKER_HEARTBEAT_SECONDS:-30}"
        worker_heartbeat
    done
    wait "$tpid" || rc=$?
    return "$rc"
}

worker_restart_service() {
    if have systemctl; then
        if [ -f /etc/systemd/system/beaut.service ]; then
            systemctl restart beaut.service 2>/dev/null && { info "restarted beaut.service"; return 0; }
        fi
        if [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/beaut.service" ]; then
            systemctl --user restart beaut.service 2>/dev/null && { info "restarted beaut.service (user)"; return 0; }
        fi
    fi
    warn "start the tunnel with: ${BEAUT_SELF:-beaut} daemon"
}

# worker_authorized_keys <user> <fingerprint> — sshd AuthorizedKeysCommand.
# Only the tunnel account gets keys; everything else is empty.
worker_authorized_keys() {
    local user=${1:-}
    has_role hub || return 0
    [ "$user" = "$TUNNEL_USER" ] || return 0
    [ -f "$(state_path tunnel_keys.tsv)" ] || return 0
    awk -F'\t' 'NF >= 2 && $2 != "" { print $2 }' "$(state_path tunnel_keys.tsv)"
}

# ---- quota-limited exec -----------------------------------------------------
# worker_exec <cpu> <mem_mib> <disk_gib> -- <cmd...>
worker_exec() {
    local cpu=$1 mem=$2 disk=$3
    shift 3
    [ "${1:-}" = "--" ] && shift
    is_uint "$cpu" && [ "$cpu" -ge 1 ] || die "worker-exec: invalid cpu '$cpu'"
    is_uint "$mem" && [ "$mem" -ge 1 ] || die "worker-exec: invalid mem '$mem'"
    is_uint "$disk" && [ "$disk" -ge 1 ] || die "worker-exec: invalid disk '$disk'"
    [ $# -gt 0 ] || die "worker-exec: empty command"
    debug "quota cpu=$cpu mem=${mem}MiB disk=${disk}GiB (disk is advisory)"
    if have systemd-run && [ -n "${XDG_RUNTIME_DIR:-}" ] \
       && [ -S "$XDG_RUNTIME_DIR/systemd/private" ]; then
        exec systemd-run --user --scope --quiet \
            -p "CPUQuota=$((cpu * 100))%" -p "MemoryMax=${mem}M" -- "$@"
    fi
    exec nice -n 10 "$@"
}
