#!/usr/bin/env bash
# lib/common.sh — config loading, state dir, logging. Sourced, never executed.
# shellcheck shell=bash

[ -n "${BEAUT_COMMON_LOADED:-}" ] && return 0
BEAUT_COMMON_LOADED=1

BEAUT_ROOT="${BEAUT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BEAUT_LIB="$BEAUT_ROOT/lib"
BEAUT_VERSION="0.1.0"

# ---- logging -----------------------------------------------------------------
# Levels: debug=0 info=1 warn=2 error=3. Everything goes to stderr so that
# subcommand stdout stays machine-readable (scripts, tokens, stats).
_lvl() {
    case "$1" in
        debug) echo 0 ;; info) echo 1 ;; warn) echo 2 ;; error) echo 3 ;; *) echo 1 ;;
    esac
}
_log() {
    local lvl="$1"; shift
    [ "$(_lvl "$lvl")" -ge "$(_lvl "${LOG_LEVEL:-info}")" ] || return 0
    printf '%s beaut[%s] %s: %s\n' "$(date -u +%FT%TZ)" "$$" "$lvl" "$*" >&2
}
debug() { _log debug "$@"; }
info()  { _log info "$@"; }
warn()  { _log warn "$@"; }
die()   { _log error "$@"; exit "${BEAUT_EXIT:-1}"; }

have() { command -v "$1" >/dev/null 2>&1; }
need() { local c; for c in "$@"; do have "$c" || die "missing dependency: $c"; done; }

# ---- config -----------------------------------------------------------------
# Resolution order (first found wins):
#   $BEAUT_CONFIG, $BEAUT_ROOT/config.env, ~/.config/beaut/config.env, /etc/beaut/config.env
# A config that exists but cannot be read is an error, never silently skipped:
# otherwise an admin would quietly operate on defaults and a private state dir.
# Environment variables BEAUT_<KEY> override any value from the file.
# Sets BEAUT_CONFIG_FILE (empty if none). Runs in the caller's shell so that
# `die` really aborts (a $(...) subshell would swallow it).
config_file() {
    local c
    BEAUT_CONFIG_FILE=""
    if [ -n "${BEAUT_CONFIG:-}" ]; then
        [ -e "$BEAUT_CONFIG" ] || die "config $BEAUT_CONFIG does not exist"
        [ -r "$BEAUT_CONFIG" ] || die "config $BEAUT_CONFIG is not readable by $(id -un)"
        BEAUT_CONFIG_FILE="$BEAUT_CONFIG"; return 0
    fi
    for c in "$BEAUT_ROOT/config.env" \
             "${XDG_CONFIG_HOME:-$HOME/.config}/beaut/config.env" /etc/beaut/config.env; do
        [ -e "$c" ] || continue
        [ -r "$c" ] || die "config $c exists but is not readable by $(id -un) (run as root or the service user)"
        BEAUT_CONFIG_FILE="$c"; return 0
    done
    return 1
}

# Keys that may come from config.env / BEAUT_<KEY> environment overrides.
config_keys=(DOMAIN ROLES NAME ADMIN_PORT ADMIN_BIND ADMINS TUNNEL_USER TUNNEL_PORT
             TUNNEL_PORT_RANGE MAIL_POLL_SECONDS MAIL_FETCH_CMD MAILDIR MAIL_FROM
             MSMTP_ACCOUNT MAIL_ACCOUNT_PATTERN GIVE_PCT WORKER_USER STATE_DIR
             LOG_LEVEL TOKEN_TTL_SECONDS TIERS)

config_defaults() {
    DOMAIN="${DOMAIN:-localhost}"
    ROLES="${ROLES:-client}"
    NAME="${NAME:-$(hostname -s 2>/dev/null || echo beaut)}"
    ADMIN_PORT="${ADMIN_PORT:-8888}"
    ADMIN_BIND="${ADMIN_BIND:-0.0.0.0}"
    ADMINS="${ADMINS:-}"
    TUNNEL_USER="${TUNNEL_USER:-tunnel}"
    TUNNEL_PORT="${TUNNEL_PORT:-22}"
    TUNNEL_PORT_RANGE="${TUNNEL_PORT_RANGE:-20000-20999}"
    MAIL_POLL_SECONDS="${MAIL_POLL_SECONDS:-60}"
    MAIL_FETCH_CMD="${MAIL_FETCH_CMD:-mpop -q}"
    MAILDIR="${MAILDIR:-$HOME/.beaut/Maildir}"
    MAIL_FROM="${MAIL_FROM:-join@$DOMAIN}"
    MSMTP_ACCOUNT="${MSMTP_ACCOUNT:-default}"
    MAIL_ACCOUNT_PATTERN="${MAIL_ACCOUNT_PATTERN:-join@*}"
    GIVE_PCT="${GIVE_PCT:-50}"
    WORKER_USER="${WORKER_USER:-beaut}"
    STATE_DIR="${STATE_DIR:-/var/lib/beaut}"
    LOG_LEVEL="${LOG_LEVEL:-info}"
    TOKEN_TTL_SECONDS="${TOKEN_TTL_SECONDS:-604800}"
    TIERS="${TIERS:-$'guest 1 2048 16\nregistered 4 4096 32\nadmin -1 -1 -1'}"
}

# Refuse config files that other users can write: they are sourced as code.
# Accepted: owned by the caller or by root, not group/world writable
# (root:beaut 0640 is the system layout: root edits, the service user reads).
config_check_perms() {
    local f="$1" mode owner
    mode=$(stat -c '%a' "$f" 2>/dev/null) || return 0
    owner=$(stat -c '%u' "$f" 2>/dev/null) || return 0
    [ "$owner" = "$(id -u)" ] || [ "$owner" = 0 ] || die "config $f not owned by you or root"
    case "$mode" in
        *[2367]|*[2367]?) die "config $f is writable by others (mode $mode); chmod 600 or 640 it" ;;
    esac
}

load_config() {
    config_file || true
    if [ -n "$BEAUT_CONFIG_FILE" ]; then
        config_check_perms "$BEAUT_CONFIG_FILE"
        # shellcheck disable=SC1090
        . "$BEAUT_CONFIG_FILE"
    fi
    # BEAUT_FOO env overrides FOO from the file — only for known config keys,
    # so that e.g. BEAUT_PATH can never rewrite PATH.
    local k v
    for k in "${config_keys[@]}"; do
        v="BEAUT_$k"
        [ -n "${!v+x}" ] && printf -v "$k" '%s' "${!v}"
    done
    # Remember whether STATE_DIR was chosen by the operator (file or env):
    # then an unwritable dir is an error, not a reason to fall back.
    BEAUT_STATE_DIR_EXPLICIT=0; [ -n "${STATE_DIR:-}" ] && BEAUT_STATE_DIR_EXPLICIT=1
    config_defaults
    validate_config
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_port() { is_uint "$1" && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

validate_config() {
    is_port "$ADMIN_PORT"  || die "ADMIN_PORT must be 1..65535 (got '$ADMIN_PORT')"
    is_port "$TUNNEL_PORT" || die "TUNNEL_PORT must be 1..65535 (got '$TUNNEL_PORT')"
    local lo="${TUNNEL_PORT_RANGE%%-*}" hi="${TUNNEL_PORT_RANGE#*-}"
    [[ "$TUNNEL_PORT_RANGE" =~ ^[0-9]+-[0-9]+$ ]] && is_port "$lo" && is_port "$hi" && [ "$lo" -le "$hi" ] \
        || die "TUNNEL_PORT_RANGE must be LOW-HIGH ports (got '$TUNNEL_PORT_RANGE')"
    is_uint "$GIVE_PCT" && [ "$GIVE_PCT" -ge 1 ] && [ "$GIVE_PCT" -le 100 ] \
        || die "GIVE_PCT must be 1..100 (got '$GIVE_PCT')"
    is_uint "$TOKEN_TTL_SECONDS" || die "TOKEN_TTL_SECONDS must be a non-negative integer"
    is_uint "$MAIL_POLL_SECONDS" && [ "$MAIL_POLL_SECONDS" -ge 1 ] || die "MAIL_POLL_SECONDS must be a positive integer"
    [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "DOMAIN contains invalid characters"
    [[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "NAME contains invalid characters"
    [[ "$ADMIN_BIND" =~ ^[A-Za-z0-9.:-]+$ ]] || die "ADMIN_BIND contains invalid characters"
    [[ "$TUNNEL_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "TUNNEL_USER is not a valid user name"
    [[ "$WORKER_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "WORKER_USER is not a valid user name"
    [[ "$STATE_DIR" = /* ]] || die "STATE_DIR must be an absolute path (got '$STATE_DIR')"
    case "$LOG_LEVEL" in debug|info|warn|error) ;; *) die "LOG_LEVEL must be debug|info|warn|error" ;; esac
    local r
    for r in $(roles); do
        case "$r" in hub|worker|client) ;; *) die "unknown role '$r' in ROLES (hub,worker,client)" ;; esac
    done
    # tiers: name cpu mem_mib disk_gib, numbers are integers (-1 = half of free)
    local n c m d x v
    while read -r n c m d x; do
        [ -n "$n" ] && [ "${n#\#}" = "$n" ] || continue
        [[ "$n" =~ ^[a-z][a-z0-9_-]*$ ]] || die "TIERS: invalid tier name '$n'"
        [ -z "$x" ] || die "TIERS: too many fields for tier '$n'"
        for v in "$c" "$m" "$d"; do
            [[ "$v" =~ ^-?[0-9]+$ ]] || die "TIERS: tier '$n' needs 3 integer fields (cpu mem_mib disk_gib)"
        done
    done <<< "$TIERS"
    tier_spec guest >/dev/null || die "TIERS must define a 'guest' tier"
}

# ---- roles ------------------------------------------------------------------
# roles            → "hub worker" (normalised, de-duplicated, lowercase)
# has_role <role>  → 0 if enabled
roles() {
    local out="" r
    for r in ${ROLES//,/ }; do
        r="${r,,}"
        case " $out " in *" $r "*) ;; *) out="$out $r" ;; esac
    done
    printf '%s\n' "${out# }"
}
has_role() { case " $(roles) " in *" $1 "*) return 0 ;; esac; return 1; }

# ---- state dir --------------------------------------------------------------
# State is a handful of TSV files. The directory is created 0700 and files 0600.
# Only when STATE_DIR was left at its default (no config, no env) and that
# default is unwritable do we fall back to a per-user dir; an explicitly
# configured STATE_DIR that cannot be used is an error, so an admin never
# silently works on a private, empty copy of the hub's state.
state_files=(workers.tsv users.tsv tokens.tsv sessions.tsv)

init_state() {
    if ! mkdir -p "$STATE_DIR" 2>/dev/null || [ ! -w "$STATE_DIR" ]; then
        [ "${BEAUT_STATE_DIR_EXPLICIT:-0}" = 0 ] \
            || die "STATE_DIR $STATE_DIR is not writable by $(id -un); run as root or the service user"
        local fb="${XDG_STATE_HOME:-$HOME/.local/state}/beaut"
        warn "default STATE_DIR $STATE_DIR not writable, using $fb"
        STATE_DIR="$fb"
        mkdir -p "$STATE_DIR" || die "cannot create state dir $STATE_DIR"
    fi
    chmod 700 "$STATE_DIR" 2>/dev/null || true
    local f
    for f in "${state_files[@]}"; do
        [ -e "$STATE_DIR/$f" ] || { : > "$STATE_DIR/$f"; chmod 600 "$STATE_DIR/$f"; }
    done
}
state_path() { printf '%s/%s\n' "$STATE_DIR" "$1"; }

# Serialise writers of a given state file: with_lock <file> cmd args...
with_lock() {
    local f="$1"; shift
    if have flock; then
        ( flock -w 10 9 || die "lock timeout on $f"; "$@" ) 9>"$f.lock"
    else
        "$@"
    fi
}

# tsv_append <file> field...   — one row, tabs/newlines in fields are stripped
tsv_append() {
    local f="$1"; shift
    local row="" x
    for x in "$@"; do x="${x//$'\t'/ }"; x="${x//$'\n'/ }"; row="$row${row:+$'\t'}$x"; done
    printf '%s\n' "$row" >> "$f"
}
# tsv_lookup <file> <col> <value> — print matching rows
tsv_lookup() { awk -F'\t' -v c="$2" -v v="$3" '$c == v' "$1"; }
# tsv_delete <file> <col> <value> — remove matching rows (atomic replace)
tsv_delete() {
    local f="$1" tmp
    tmp=$(mktemp "$f.XXXXXX") || return 1
    awk -F'\t' -v c="$2" -v v="$3" '$c != v' "$f" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$f"
}

# ---- tiers ------------------------------------------------------------------
# tier_spec <name> → "cpu mem_mib disk_gib" or non-zero if unknown
tier_spec() {
    local n c m d
    while read -r n c m d; do
        [ -n "$n" ] && [ "${n#\#}" = "$n" ] || continue
        [ "$n" = "$1" ] && { printf '%s %s %s\n' "$c" "$m" "$d"; return 0; }
    done <<< "$TIERS"
    return 1
}
tier_names() { awk 'NF >= 4 && $1 !~ /^#/ {print $1}' <<< "$TIERS"; }

now() { date +%s; }
