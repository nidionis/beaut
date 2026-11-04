#!/usr/bin/env bash
# lib/hub.sh — worker registry, scheduler and remote execution. Sourced.
# shellcheck shell=bash
#
# workers.tsv : name tunnel_port cpu_pct cpu_total mem_free_mib disk_free_gib
#               last_seen worker_user beaut_path
# sessions.tsv: id user worker kind(cmd|vm) cpu mem disk started_ts
# tunnel_keys.tsv: name ssh_pubkey added_ts   (read by `beaut __authorized-keys`)

[ -n "${BEAUT_HUB_LOADED:-}" ] && return 0
BEAUT_HUB_LOADED=1

# ---- hub ssh identity -------------------------------------------------------
# The hub uses this key to log into workers through their reverse tunnel. The
# matching public key is fetched by `beaut enroll` and added to the worker's
# authorized_keys. The private key lives in the state dir (0600).
_hub_ensure_key() {
    [ -s "$HUB_KEY" ] && [ -s "$HUB_KEY.pub" ] && return 0
    mkdir -p "$(dirname "$HUB_KEY")"
    rm -f "$HUB_KEY" "$HUB_KEY.pub"
    ssh-keygen -q -t ed25519 -N '' -C "beaut-hub@${NAME:-beaut}" -f "$HUB_KEY" >/dev/null
    chmod 600 "$HUB_KEY"
    chmod 644 "$HUB_KEY.pub"
}
hub_ensure_key() {
    need ssh-keygen
    mkdir -p "$(dirname "$HUB_KEY")"
    with_lock "$HUB_KEY.lock" _hub_ensure_key
}
hub_pubkey() {
    [ -s "$HUB_KEY.pub" ] || hub_ensure_key
    cat "$HUB_KEY.pub"
}

# ---- capacity ---------------------------------------------------------------
# hub_used <worker> — "cpu mem disk" allocated to that worker by sessions.tsv.
hub_used() {
    awk -F'\t' -v w="$1" '$3 == w { c += $5; m += $6; d += $7 }
        END { printf "%d %d %d\n", c + 0, m + 0, d + 0 }' "$(state_path sessions.tsv)"
}

# hub_pick <cpu> <mem_mib> <disk_gib> — print a fitting worker, or fail.
# A requested value of -1 means "half of that worker's free capacity" (admin).
# Output: name<TAB>port<TAB>cpu<TAB>mem<TAB>disk<TAB>worker_user<TAB>beaut_path
hub_pick() {
    local rcpu=$1 rmem=$2 rdisk=$3
    local cutoff name port pct cpu mem disk seen user self
    local uc um ud fc fm fd nc nm nd best="" best_score=-1 score

    cutoff=$(( $(now) - WORKER_STALE_SECONDS ))
    while IFS=$'\t' read -r name port pct cpu mem disk seen user self; do
        [ -n "$name" ] || continue
        [[ "$seen" =~ ^[0-9]+$ ]] || continue
        [ "$seen" -ge "$cutoff" ] || continue
        [[ "$cpu" =~ ^[0-9]+$ ]] || continue
        [[ "$mem" =~ ^[0-9]+$ ]] || continue
        [[ "$disk" =~ ^[0-9]+$ ]] || continue

        read -r uc um ud <<< "$(hub_used "$name")"
        fc=$(( cpu - uc )); [ "$fc" -ge 0 ] || fc=0
        fm=$(( mem - um )); [ "$fm" -ge 0 ] || fm=0
        fd=$(( disk - ud )); [ "$fd" -ge 0 ] || fd=0

        nc=$rcpu; nm=$rmem; nd=$rdisk
        if [ "$nc" = -1 ]; then nc=$(( fc / 2 )); [ "$nc" -ge 1 ] || nc=1; fi
        if [ "$nm" = -1 ]; then nm=$(( fm / 2 )); [ "$nm" -ge 1 ] || nm=1; fi
        if [ "$nd" = -1 ]; then nd=$(( fd / 2 )); [ "$nd" -ge 1 ] || nd=1; fi

        [ "$nc" -le "$fc" ] && [ "$nm" -le "$fm" ] && [ "$nd" -le "$fd" ] || continue
        score=$fm
        if [ "$score" -gt "$best_score" ]; then
            best_score=$score
            best="$name"$'\t'"$port"$'\t'"$nc"$'\t'"$nm"$'\t'"$nd"$'\t'"${user:-$WORKER_USER}"$'\t'"${self:-beaut}"
        fi
    done < "$(state_path workers.tsv)"
    [ -n "$best" ] || return 1
    printf '%s\n' "$best"
}

# ---- reservation ------------------------------------------------------------
# _hub_reserve <email> <cpu> <mem> <disk> — under sessions.tsv lock.
# Picks a worker, records the session, prints the same fields as hub_pick plus
# the new session id as the first field.
_hub_reserve() {
    local email=$1 rcpu=$2 rmem=$3 rdisk=$4 pick id
    pick=$(hub_pick "$rcpu" "$rmem" "$rdisk") || return 4
    id="s$(now)-$$-$RANDOM"
    local name port cpu mem disk user self
    IFS=$'\t' read -r name port cpu mem disk user self <<< "$pick"
    tsv_append "$(state_path sessions.tsv)" \
        "$id" "$email" "$name" cmd "$cpu" "$mem" "$disk" "$(now)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$id" "$name" "$port" "$cpu" "$mem" "$disk" "$user" "$self"
}
hub_reserve() {
    with_lock "$(state_path sessions.tsv)" _hub_reserve "$@"
}

# hub_run <email> <cmd...> — schedule and execute on a worker.
# Returns the remote command's status, 4 if no worker fits, or 5 if the SSH
# connection/setup itself failed (ssh exits 255).
hub_run() {
    local email=$1; shift
    [ $# -gt 0 ] || { warn "empty command"; return 2; }
    local tier spec pick id name port cpu mem disk user self rc=0
    tier=$(user_tier "$email")
    spec=$(tier_spec "$tier") || spec="1 2048 16"
    # shellcheck disable=SC2086
    pick=$(hub_reserve "$email" $spec) || return 4
    IFS=$'\t' read -r id name port cpu mem disk user self <<< "$pick"
    [ -n "$self" ] || self=beaut
    hub_ensure_key

    local -a cmd=(ssh -i "$HUB_KEY" -p "$port"
        -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=10
        -o StrictHostKeyChecking=accept-new
        -o UserKnownHostsFile="$STATE_DIR/known_hosts"
        "$user@127.0.0.1" "$self" worker-exec "$cpu" "$mem" "$disk" -- "$@")
    if is_uint "${RUN_TIMEOUT:-0}" && [ "$RUN_TIMEOUT" -gt 0 ]; then
        cmd=(timeout "$RUN_TIMEOUT" "${cmd[@]}")
    fi
    debug "run $id on $name:$port ($cpu cpu, ${mem}MiB, ${disk}GiB) as $user"
    "${cmd[@]}" || rc=$?
    tsv_delete "$(state_path sessions.tsv)" 1 "$id"
    [ "$rc" = 255 ] && rc=5
    return "$rc"
}
