#!/usr/bin/env bash
# lib/client.sh — submit a command to the pool. Sourced.
# shellcheck shell=bash
#
# Clients use the reusable token embedded by the /client/<token> installer.
# The hub runs the command on a worker and returns stdout + an X-Beaut-Exit
# header. A hub host can also run locally, without HTTP, as its first admin.

[ -n "${BEAUT_CLIENT_LOADED:-}" ] && return 0
BEAUT_CLIENT_LOADED=1

client_run() {
    [ $# -gt 0 ] || die "usage: beaut run <cmd...>"

    if [ -n "${CLIENT_TOKEN:-}" ]; then
        need curl
        local base cmd hdr body status exitcode
        base=$(hub_url)
        cmd=$(printf '%q ' "$@")
        hdr=$(mktemp); body=$(mktemp)
        # shellcheck disable=SC2064
        trap "rm -f '$hdr' '$body'" EXIT
        curl -sS --noproxy '*' -D "$hdr" -o "$body" -X POST \
            --data-urlencode "token=$CLIENT_TOKEN" \
            --data-urlencode "cmd=$cmd" "$base/run" || die "cannot reach $base"
        status=$(awk 'NR == 1 {print $2}' "$hdr")
        exitcode=$(awk 'BEGIN {IGNORECASE=1} /^X-Beaut-Exit:/ {gsub("\r", ""); print $2}' "$hdr")
        cat "$body"
        # A remote command that exits non-zero still carries X-Beaut-Exit; a
        # transport error (no worker, bad token) does not.
        if is_uint "${exitcode:-}"; then return "$exitcode"; fi
        [ "$status" = 200 ] || return 1
        return 0
    fi

    if has_role hub; then
        local email="${CLIENT_EMAIL:-${ADMINS%% *}}" rc=0
        [ -n "$email" ] || die "set ADMINS or CLIENT_EMAIL to run locally"
        hub_run "$email" "$@" || rc=$?
        case "$rc" in
            0) ;;
            4) die "no worker fits the requested tier" ;;
            5) die "worker connection failed" ;;
            *) return "$rc" ;;
        esac
        return 0
    fi

    die "no client token: install from the /client/<token> one-liner"
}
