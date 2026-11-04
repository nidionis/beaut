#!/usr/bin/env bash
# lib/auth.sh — tokens, users.tsv, admin list, ssh-key helpers. Sourced.
# shellcheck shell=bash
#
# users.tsv  : email  ssh_pubkey  level(guest|registered|admin)  approved_ts
# tokens.tsv : token  email  created_ts  used(0/1)

[ -n "${BEAUT_AUTH_LOADED:-}" ] && return 0
BEAUT_AUTH_LOADED=1

# ---- validation ---------------------------------------------------------------
valid_email() { [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && [ "${#1}" -le 254 ]; }
valid_token() { [[ "$1" =~ ^[a-f0-9]{32}$ ]]; }
valid_level() { case "$1" in guest|registered|admin) return 0 ;; esac; return 1; }

# ---- ssh keys -----------------------------------------------------------------
# ssh_key_valid <line> — true if it looks like an OpenSSH public key.
ssh_key_valid() {
    local k="$1"
    [[ "$k" =~ ^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256))(@openssh\.com)?\ [A-Za-z0-9+/]+=*(\ [^[:space:]]*)?$ ]] \
        || return 1
    if have ssh-keygen; then
        ssh-keygen -l -f /dev/stdin <<< "$k" >/dev/null 2>&1
    fi
}
# ssh_key_extract — print the first valid public key found on stdin, if any.
ssh_key_extract() {
    local line
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"   # ltrim
        line="${line%"${line##*[![:space:]]}"}"   # rtrim
        ssh_key_valid "$line" && { printf '%s\n' "$line"; return 0; }
    done
    return 1
}
ssh_key_fingerprint() { ssh-keygen -l -f /dev/stdin <<< "$1" 2>/dev/null | awk '{print $2}'; }

# ---- admins -------------------------------------------------------------------
# Admins are the ADMINS list in config plus users.tsv rows at level admin.
is_admin() {
    local a
    for a in $ADMINS; do [ "${a,,}" = "${1,,}" ] && return 0; done
    [ "$(user_level "$1")" = "admin" ]
}

# ---- users --------------------------------------------------------------------
user_get()   { tsv_lookup "$(state_path users.tsv)" 1 "${1,,}" | head -n1; }
user_exists(){ [ -n "$(user_get "$1")" ]; }
user_level() {
    local row; row=$(user_get "$1")
    [ -n "$row" ] && awk -F'\t' '{print $3}' <<< "$row"
}
user_key() {
    local row; row=$(user_get "$1")
    [ -n "$row" ] && awk -F'\t' '{print $2}' <<< "$row"
}
# user_add <email> [pubkey] [level] — pending users carry approved_ts=0
_user_add() {
    local email="${1,,}" key="${2:-}" level="${3:-guest}" f
    f=$(state_path users.tsv)
    valid_email "$email" || die "invalid email: $1"
    valid_level "$level" || die "invalid level: $level"
    [ -z "$key" ] || ssh_key_valid "$key" || die "invalid ssh public key"
    user_exists "$email" && die "user $email already exists (use 'user level' or 'user rm')"
    tsv_append "$f" "$email" "$key" "$level" 0
}
user_add() { with_lock "$(state_path users.tsv)" _user_add "$@"; }

# user_set_level <email> <level> — stamps approved_ts when leaving guest
_user_set_level() {
    local email="${1,,}" level="$2" f row key ts
    f=$(state_path users.tsv)
    valid_level "$level" || die "invalid level: $level"
    row=$(user_get "$email"); [ -n "$row" ] || die "unknown user: $email"
    key=$(awk -F'\t' '{print $2}' <<< "$row")
    ts=$(now); [ "$level" = guest ] && ts=0
    tsv_delete "$f" 1 "$email"
    tsv_append "$f" "$email" "$key" "$level" "$ts"
}
user_set_level() { with_lock "$(state_path users.tsv)" _user_set_level "$@"; }
user_approve() { user_set_level "$1" registered; }
user_remove()  { with_lock "$(state_path users.tsv)" tsv_delete "$(state_path users.tsv)" 1 "${1,,}"; }
users_pending(){ awk -F'\t' '$4 == 0 {print $1}' "$(state_path users.tsv)"; }
users_list()   { cat "$(state_path users.tsv)"; }

# user_tier <email> → tier name used by the scheduler (unknown → guest)
user_tier() {
    local l=""
    l=$(user_level "$1") || l=""
    case "$l" in
        admin|registered) printf '%s\n' "$l" ;;
        *) if is_admin "$1"; then printf 'admin\n'; else printf 'guest\n'; fi ;;
    esac
}

# ---- tokens -------------------------------------------------------------------
token_new() {
    if [ -r /dev/urandom ]; then
        od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
    else
        printf '%s%s%s' "$RANDOM$RANDOM" "$(now)" "$$" | sha256sum | cut -c1-32
    fi
    echo
}
# token_issue <email> → prints the token
_token_issue() {
    local email="${1,,}" t
    valid_email "$email" || die "invalid email: $1"
    t=$(token_new)
    tsv_append "$(state_path tokens.tsv)" "$t" "$email" "$(now)" 0
    printf '%s\n' "$t"
}
token_issue() { with_lock "$(state_path tokens.tsv)" _token_issue "$@"; }

# token_check <token> → prints the owner email if valid, unused and unexpired
token_check() {
    local t="$1" row email created used
    valid_token "$t" || return 1
    row=$(tsv_lookup "$(state_path tokens.tsv)" 1 "$t" | head -n1)
    [ -n "$row" ] || return 1
    IFS=$'\t' read -r _ email created used <<< "$row"
    [ "$used" = 0 ] || return 1
    [ $(( $(now) - created )) -le "$TOKEN_TTL_SECONDS" ] || return 1
    printf '%s\n' "$email"
}
# token_burn <token> → prints owner email and marks it used; fails if invalid
_token_burn() {
    local t="$1" email f
    f=$(state_path tokens.tsv)
    email=$(token_check "$t") || return 1
    local row created
    row=$(tsv_lookup "$f" 1 "$t" | head -n1)
    created=$(awk -F'\t' '{print $3}' <<< "$row")
    tsv_delete "$f" 1 "$t"
    tsv_append "$f" "$t" "$email" "$created" 1
    printf '%s\n' "$email"
}
token_burn() { with_lock "$(state_path tokens.tsv)" _token_burn "$@"; }
tokens_prune() {
    local f tmp cutoff
    f=$(state_path tokens.tsv); cutoff=$(( $(now) - TOKEN_TTL_SECONDS ))
    tmp=$(mktemp "$f.XXXXXX") || return 1
    awk -F'\t' -v c="$cutoff" '$3 > c && $4 == 0' "$f" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$f"
}

# ---- reusable client tokens ---------------------------------------------------
# clients.tsv : email  token  created_ts
# Issued when a one-time enrollment token is redeemed; used by `beaut run`.
_client_token_issue() {
    local email="${1,,}" t f
    valid_email "$email" || die "invalid email: $1"
    f=$(state_path clients.tsv)
    t=$(token_new)
    tsv_delete "$f" 1 "$email"
    tsv_append "$f" "$email" "$t" "$(now)"
    printf '%s\n' "$t"
}
client_token_issue() { with_lock "$(state_path clients.tsv)" _client_token_issue "$@"; }

# client_token_check <token> → owner email if valid and unexpired.
client_token_check() {
    local t=$1 row email created
    valid_token "$t" || return 1
    row=$(tsv_lookup "$(state_path clients.tsv)" 2 "$t" | head -n1)
    [ -n "$row" ] || return 1
    IFS=$'\t' read -r email _ created <<< "$row"
    if [ "${CLIENT_TOKEN_TTL_SECONDS:-0}" -gt 0 ] \
       && [ $(( $(now) - created )) -gt "$CLIENT_TOKEN_TTL_SECONDS" ]; then
        return 1
    fi
    printf '%s\n' "$email"
}
client_token_revoke() {
    with_lock "$(state_path clients.tsv)" tsv_delete "$(state_path clients.tsv)" 1 "${1,,}"
}
