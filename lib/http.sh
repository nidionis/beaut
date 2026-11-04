#!/usr/bin/env bash
# lib/http.sh — HTTP stats + enrollment app on :$ADMIN_PORT. Sourced.
# shellcheck shell=bash
#
# `beaut serve` runs one `socat` listener; each connection is handed to
# `beaut __http`, which parses the request on stdin and writes the response on
# stdout. Nothing user-supplied is ever interpolated into a response header or
# into a shell command: routes are matched with fixed patterns, values are
# validated, and the generated installers only embed validated config values.
#
# Endpoints:
#   GET  /                 plain-text stats
#   GET  /stats            plain-text stats
#   GET  /stats.json       JSON stats
#   GET  /health           "ok"
#   GET  /give<N>          worker installer (N clamped to 1..100)
#   POST /register         worker capacity + tunnel port (port=0 → auto)
#   GET  /client/<token>   one-time client installer (burns the token)
#   GET  /beaut.tar.gz     the bash tree, for the generated installers

[ -n "${BEAUT_HTTP_LOADED:-}" ] && return 0
BEAUT_HTTP_LOADED=1

HTTP_MAX_LINE=4096          # request line and total header bytes
HTTP_MAX_HEADERS=100
HTTP_MAX_BODY=65536         # /register forms are tiny
HTTP_TIMEOUT=10             # per-read inactivity timeout, seconds

# hub_url — public base URL of this hub. TLS belongs in a reverse proxy.
hub_url() {
    if [ "$ADMIN_PORT" = 80 ]; then
        printf 'http://%s\n' "$DOMAIN"
    else
        printf 'http://%s:%s\n' "$DOMAIN" "$ADMIN_PORT"
    fi
}

# shquote <s> — POSIX single-quote a value for a /bin/sh command line.
shquote() {
    local s=$1
    s=${s//\'/\'\\\'\'}
    printf "'%s'" "$s"
}

# url_decode <s> — decode application/x-www-form-urlencoded text without
# interpreting backslashes (a command may legitimately contain them).
url_decode() {
    local s=${1//+/ } out="" h c
    while [[ "$s" == *%* ]]; do
        out+=${s%%%*}
        s=${s#*%}
        h=${s:0:2}
        if [[ "$h" =~ ^[0-9A-Fa-f]{2}$ ]]; then
            printf -v c "\\x$h"
            out+=$c
            s=${s:2}
        else
            out+='%'
        fi
    done
    printf '%s' "$out$s"
}

# ---- server -----------------------------------------------------------------

http_serve() {
    need socat
    init_state
    hub_ensure_key
    case "$BEAUT_ROOT" in
        *,*) die "BEAUT_ROOT must not contain a comma (socat address syntax): $BEAUT_ROOT" ;;
    esac
    local cmd
    cmd="$(shquote "$BEAUT_ROOT/bin/beaut") __http"
    info "serving http://$ADMIN_BIND:$ADMIN_PORT/ (domain $DOMAIN)"
    # fork: one handler per connection; SYSTEM: run through /bin/sh so that a
    # path containing spaces survives. No socat -T: `beaut run` may legitimately
    # take longer than a request-read timeout (the parser has its own -t).
    socat "TCP-LISTEN:$ADMIN_PORT,bind=$ADMIN_BIND,reuseaddr,fork" \
        "SYSTEM:$cmd"
}

# ---- response helpers -------------------------------------------------------

http_headers() { # status-line content-type content-length
    printf 'HTTP/1.1 %s\r\n' "$1"
    printf 'Content-Type: %s\r\n' "$2"
    printf 'Content-Length: %s\r\n' "$3"
    printf 'Connection: close\r\n'
    printf 'Cache-Control: no-store\r\n'
    printf 'X-Content-Type-Options: nosniff\r\n'
    printf '\r\n'
}

http_send() { # status-line content-type body
    local status=$1 ctype=$2 body=$3 size
    size=$(printf '%s' "$body" | wc -c)
    http_headers "$status" "$ctype" "$size"
    printf '%s' "$body"
}

http_send_file() { # status-line content-type file
    local status=$1 ctype=$2 file=$3 size
    size=$(wc -c < "$file")
    http_headers "$status" "$ctype" "$size"
    cat "$file"
}

http_error() { # status-line message
    http_send "$1" 'text/plain; charset=utf-8' "$2"$'\n'
}

# http_send_exit <status-line> <content-type> <body> <remote-exit-code>
http_send_exit() {
    local status=$1 ctype=$2 body=$3 code=$4 size
    size=$(printf '%s' "$body" | wc -c)
    printf 'HTTP/1.1 %s\r\n' "$status"
    printf 'Content-Type: %s\r\n' "$ctype"
    printf 'Content-Length: %s\r\n' "$size"
    printf 'X-Beaut-Exit: %s\r\n' "$code"
    printf 'Connection: close\r\n'
    printf 'Cache-Control: no-store\r\n'
    printf 'X-Content-Type-Options: nosniff\r\n'
    printf '\r\n'
    printf '%s' "$body"
}

# ---- request parsing --------------------------------------------------------

# http_handle — one request/response exchange (stdin/stdout are the socket).
http_handle() {
    init_state
    local method="" path="" version="" line="" len="" len_set=0 expect_continue=0
    local headers_done=0 hdr_count=0 hdr_bytes=0 body="" lower

    if ! IFS=' ' read -r -t "$HTTP_TIMEOUT" method path version; then
        http_error '408 Request Timeout' 'request timeout'
        return 0
    fi
    method=${method%$'\r'}; path=${path%$'\r'}; version=${version%$'\r'}

    if [ ${#method} -gt 16 ] || [ ${#path} -gt "$HTTP_MAX_LINE" ]; then
        http_error '414 URI Too Long' 'request line too long'
        return 0
    fi
    case "$version" in
        HTTP/1.0|HTTP/1.1) ;;
        *) http_error '400 Bad Request' 'unsupported HTTP version'; return 0 ;;
    esac
    if [[ "$path" != /* ]] || [[ "$path" == *[[:cntrl:]]* ]]; then
        http_error '400 Bad Request' 'bad request path'
        return 0
    fi
    path=${path%%\?*}

    while IFS= read -r -t "$HTTP_TIMEOUT" line; do
        line=${line%$'\r'}
        if [ -z "$line" ]; then headers_done=1; break; fi
        hdr_count=$((hdr_count + 1))
        hdr_bytes=$((hdr_bytes + ${#line}))
        if [ "$hdr_count" -gt "$HTTP_MAX_HEADERS" ] || [ "$hdr_bytes" -gt "$HTTP_MAX_LINE" ]; then
            http_error '431 Request Header Fields Too Large' 'request headers too large'
            return 0
        fi
        lower=${line,,}
        case "$lower" in
            content-length:*)
                if [ "$len_set" = 1 ]; then
                    http_error '400 Bad Request' 'duplicate content-length'
                    return 0
                fi
                len=${line#*:}
                len=${len//[[:space:]]/}
                if ! [[ "$len" =~ ^[0-9]{1,9}$ ]]; then
                    http_error '400 Bad Request' 'bad content-length'
                    return 0
                fi
                len_set=1
                ;;
            transfer-encoding:*)
                http_error '411 Length Required' 'transfer-encoding is not supported'
                return 0
                ;;
            expect:*continue*)
                expect_continue=1
                ;;
        esac
    done
    if [ "$headers_done" = 0 ]; then
        http_error '400 Bad Request' 'incomplete headers'
        return 0
    fi

    if [ "$method" = POST ]; then
        if [ "$len_set" = 0 ]; then
            http_error '411 Length Required' 'content-length required'
            return 0
        fi
        if [ "$len" -gt "$HTTP_MAX_BODY" ]; then
            http_error '413 Payload Too Large' 'request body too large'
            return 0
        fi
        if [ "$len" -gt 0 ] && [ "$expect_continue" = 1 ]; then
            printf 'HTTP/1.1 100 Continue\r\n\r\n'
        fi
        if [ "$len" -gt 0 ]; then
            if ! IFS= read -r -N "$len" -t "$HTTP_TIMEOUT" body; then
                http_error '400 Bad Request' 'incomplete body'
                return 0
            fi
            if [ "${#body}" -ne "$len" ]; then
                http_error '400 Bad Request' 'incomplete body'
                return 0
            fi
        fi
    fi

    # Route by path first so that a known path with the wrong method is 405,
    # while an unknown path stays 404 whatever the method.
    case "$path" in
        /|/stats|/stats.json|/health|/hubkey|/beaut.tar.gz|/give*|/client/*)
            if [ "$method" != GET ]; then
                http_error '405 Method Not Allowed' 'method not allowed'
                return 0
            fi
            case "$path" in
                /|/stats)      http_send '200 OK' 'text/plain; charset=utf-8' "$(stats_text)"$'\n' ;;
                /stats.json)   http_send '200 OK' 'application/json' "$(stats_json)"$'\n' ;;
                /health)       http_send '200 OK' 'text/plain; charset=utf-8' $'ok\n' ;;
                /hubkey)       http_hubkey ;;
                /beaut.tar.gz) http_tarball ;;
                /give*)        http_give "$path" ;;
                /client/*)     http_client "${path#/client/}" ;;
            esac
            ;;
        /register|/run|/heartbeat)
            if [ "$method" != POST ]; then
                http_error '405 Method Not Allowed' 'method not allowed'
                return 0
            fi
            case "$path" in
                /register)  http_register "$body" ;;
                /run)       http_run "$body" ;;
                /heartbeat) http_heartbeat "$body" ;;
            esac
            ;;
        *)
            http_error '404 Not Found' 'not found'
            ;;
    esac
    return 0
}

# ---- endpoints --------------------------------------------------------------

# GET /give<N> — worker installer; N is clamped to 1..100.
http_give() {
    local path=$1 n script
    if ! [[ "$path" =~ ^/give([0-9]{1,3})$ ]]; then
        http_error '400 Bad Request' 'usage: /give<N> with 1 <= N <= 100'
        return 0
    fi
    n=$((10#${BASH_REMATCH[1]}))
    [ "$n" -lt 1 ] && n=1
    [ "$n" -gt 100 ] && n=100
    if ! script=$(render_worker_installer "$n"); then
        http_error '500 Internal Server Error' 'cannot render installer'
        return 0
    fi
    http_send '200 OK' 'text/x-shellscript; charset=utf-8' "$script"$'\n'
}

# GET /client/<token> — burn a one-time token, return the client installer.
http_client() {
    local token=$1 email script
    if ! valid_token "$token"; then
        http_error '404 Not Found' 'not found'
        return 0
    fi
    if ! email=$(token_burn "$token"); then
        http_error '410 Gone' 'token is invalid, used or expired'
        return 0
    fi
    if ! script=$(render_client_installer "$email"); then
        http_error '500 Internal Server Error' 'cannot issue client token'
        return 0
    fi
    info "client installer issued to $email"
    http_send '200 OK' 'text/x-shellscript; charset=utf-8' "$script"$'\n'
}

# GET /hubkey — public half of the hub's worker-login key.
http_hubkey() {
    local key
    if ! key=$(hub_pubkey); then
        http_error '500 Internal Server Error' 'hub key unavailable'
        return 0
    fi
    http_send '200 OK' 'text/plain; charset=utf-8' "$key"$'\n'
}

# POST /heartbeat — name=<worker>; refresh last_seen.
http_heartbeat() {
    local body=$1 name="" pair
    local -a pairs
    IFS='&' read -r -a pairs <<< "$body"
    for pair in "${pairs[@]}"; do
        case "${pair%%=*}" in
            name) name=$(url_decode "${pair#*=}") ;;
        esac
    done
    if ! [[ "$name" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
        http_error '400 Bad Request' 'invalid name'
        return 0
    fi
    if with_lock "$(state_path workers.tsv)" _http_heartbeat_apply "$name"; then
        http_send '200 OK' 'text/plain; charset=utf-8' $'ok\n'
    else
        http_error '404 Not Found' 'unknown worker'
    fi
}

_http_heartbeat_apply() {
    local name=$1 f tmp
    f=$(state_path workers.tsv)
    tmp=$(mktemp "$f.XXXXXX") || return 1
    if ! awk -F'\t' -v n="$name" -v t="$(now)" 'BEGIN {OFS="\t"}
            $1 == n { $7 = t; found = 1 }
            { print }
            END { exit !found }' "$f" > "$tmp"; then
        rm -f "$tmp"; return 1
    fi
    chmod 600 "$tmp"; mv -f "$tmp" "$f"
}

# POST /run — token=<client token>&cmd=<shell command>; run on a worker.
http_run() {
    local body=$1 token="" cmd="" pair out rc=0 status
    local -a pairs
    IFS='&' read -r -a pairs <<< "$body"
    for pair in "${pairs[@]}"; do
        case "${pair%%=*}" in
            token) token=$(url_decode "${pair#*=}") ;;
            cmd)   cmd=$(url_decode "${pair#*=}") ;;
        esac
    done
    if [ -z "$token" ] || [ -z "$cmd" ]; then
        http_error '400 Bad Request' 'token and cmd are required'
        return 0
    fi
    local email
    if ! email=$(client_token_check "$token"); then
        http_error '403 Forbidden' 'invalid or expired client token'
        return 0
    fi
    if ! user_exists "$email"; then
        http_error '403 Forbidden' 'unknown user'
        return 0
    fi
    rc=0
    out=$(hub_run "$email" bash -c "$cmd" 2>&1) || rc=$?
    case "$rc" in
        0) status='200 OK' ;;
        4) status='503 Service Unavailable'
           [ -n "$out" ] || out='no worker fits the requested tier' ;;
        5) status='500 Internal Server Error'
           [ -n "$out" ] || out='worker connection failed' ;;
        *) status='500 Internal Server Error' ;;
    esac
    http_send_exit "$status" 'text/plain; charset=utf-8' "$out"$'\n' "$rc"
}

# POST /register — upsert a worker. Accepts form-urlencoded key=value pairs or
# the legacy positional body "name&port&cpu_pct&cpu_total&mem&disk".
http_register() {
    local body=$1 name="" port="" pct="" cpu="" mem="" disk="" extra=""
    local pubkey="" wuser="" self="" pair key val rc=0 out
    local -a pairs

    if [[ "$body" == *=* ]]; then
        IFS='&' read -r -a pairs <<< "$body"
        for pair in "${pairs[@]}"; do
            key=$(url_decode "${pair%%=*}"); val=$(url_decode "${pair#*=}")
            case "$key" in
                name)                     name=$val ;;
                port)                     port=$val ;;
                cpu_pct)                  pct=$val ;;
                cpu_total)                cpu=$val ;;
                mem_free_mib|mem)         mem=$val ;;
                disk_free_gib|disk)       disk=$val ;;
                pubkey)                   pubkey=$val ;;
                user)                     wuser=$val ;;
                self)                     self=$val ;;
                *)                        : ;;
            esac
        done
    else
        IFS='&' read -r name port pct cpu mem disk extra <<< "$body"
        if [ -n "$extra" ]; then
            http_error '400 Bad Request' 'too many fields'
            return 0
        fi
    fi

    if ! [[ "$name" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
        http_error '400 Bad Request' 'invalid name'
        return 0
    fi
    if [ "$port" != 0 ] && ! is_port "$port"; then
        http_error '400 Bad Request' 'invalid port (use 0 for auto)'
        return 0
    fi
    if ! { is_uint "$pct" && [ "$pct" -ge 1 ] && [ "$pct" -le 100 ]; }; then
        http_error '400 Bad Request' 'cpu_pct must be 1..100'
        return 0
    fi
    if ! { is_uint "$cpu" && [ "$cpu" -ge 1 ] && [ "$cpu" -le 4096 ]; }; then
        http_error '400 Bad Request' 'cpu_total must be 1..4096'
        return 0
    fi
    if ! { is_uint "$mem" && [ "$mem" -ge 1 ] && [ "$mem" -le 1048576 ]; }; then
        http_error '400 Bad Request' 'mem_free_mib must be 1..1048576'
        return 0
    fi
    if ! { is_uint "$disk" && [ "$disk" -ge 1 ] && [ "$disk" -le 1048576 ]; }; then
        http_error '400 Bad Request' 'disk_free_gib must be 1..1048576'
        return 0
    fi
    if [ -n "$wuser" ] && ! [[ "$wuser" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        http_error '400 Bad Request' 'invalid worker user'
        return 0
    fi
    if [ -n "$self" ] && ! [[ "$self" =~ ^/[A-Za-z0-9._/+:-]+$ ]]; then
        http_error '400 Bad Request' 'invalid beaut path'
        return 0
    fi
    if [ -n "$pubkey" ] && ! ssh_key_valid "$pubkey"; then
        http_error '400 Bad Request' 'invalid ssh public key'
        return 0
    fi

    if out=$(with_lock "$(state_path workers.tsv)" _http_register_apply \
             "$name" "$port" "$pct" "$cpu" "$mem" "$disk" "$wuser" "$self" "$pubkey"); then
        info "worker registered: $name port=$out"
        http_send '200 OK' 'text/plain; charset=utf-8' "ok port=$out"$'\n'
        return 0
    fi
    rc=$?
    if [ "$rc" = 3 ]; then
        http_error '503 Service Unavailable' 'no free tunnel port'
    else
        http_error '503 Service Unavailable' 'worker registry busy, retry'
    fi
}

# _http_register_apply <name> <port|0> <pct> <cpu> <mem> <disk> [user] [self] [pubkey]
# Under the workers.tsv lock. Reuses an existing port when port=0 so a
# re-enrollment does not move a live tunnel.
_http_register_apply() {
    local name=$1 port=$2 pct=$3 cpu=$4 mem=$5 disk=$6
    local wuser=${7:-} self=${8:-} pubkey=${9:-} f old
    f=$(state_path workers.tsv)
    old=$(tsv_lookup "$f" 1 "$name" | head -n1 | cut -f2)
    if [ "$port" = 0 ]; then
        if [ -n "$old" ] && is_port "$old"; then
            port=$old
        else
            port=$(http_alloc_port) || return 3
        fi
    fi
    tsv_delete "$f" 1 "$name"
    tsv_append "$f" "$name" "$port" "$pct" "$cpu" "$mem" "$disk" "$(now)" "$wuser" "$self"
    if [ -n "$pubkey" ]; then
        local kf
        kf=$(state_path tunnel_keys.tsv)
        tsv_delete "$kf" 1 "$name"
        tsv_append "$kf" "$name" "$pubkey" "$(now)"
    fi
    printf '%s\n' "$port"
}

# http_alloc_port — first port of TUNNEL_PORT_RANGE not present in workers.tsv.
http_alloc_port() {
    local lo hi p used
    lo=${TUNNEL_PORT_RANGE%%-*}
    hi=${TUNNEL_PORT_RANGE#*-}
    used=" $(awk -F'\t' 'NF {printf "%s ", $2}' "$(state_path workers.tsv)") "
    for ((p = lo; p <= hi; p++)); do
        case "$used" in
            *" $p "*) ;;
            *) printf '%s\n' "$p"; return 0 ;;
        esac
    done
    return 1
}

# GET /beaut.tar.gz — the installed bash tree, minus config/state.
http_tarball() {
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/beaut-http.XXXXXX") || {
        http_error '500 Internal Server Error' 'cannot create temporary file'
        return 0
    }
    local -a files=(bin lib install.sh config.env.example beaut.service)
    [ -d "$BEAUT_ROOT/docs" ] && files+=(docs)
    if ! tar -czf "$tmp" -C "$BEAUT_ROOT" "${files[@]}" 2>/dev/null; then
        rm -f "$tmp"
        http_error '500 Internal Server Error' 'cannot build bundle'
        return 0
    fi
    http_send_file '200 OK' 'application/gzip' "$tmp"
    rm -f "$tmp"
}

# ---- installers -------------------------------------------------------------

# render_worker_installer <pct> — one-line worker enrollment script.
render_worker_installer() {
    local pct=$1 base
    base=$(hub_url)
    cat <<EOF
#!/bin/sh
# beaut worker installer — donate ${pct}% of this machine to ${DOMAIN}.
#   curl -fsSL '${base}/give${pct}' | sudo sh
set -eu
BASE='${base}'
PCT='${pct}'
DOMAIN='${DOMAIN}'
ADMIN_PORT='${ADMIN_PORT}'
TUNNEL_USER='${TUNNEL_USER}'
TUNNEL_PORT='${TUNNEL_PORT}'
if [ "\$(id -u)" != 0 ]; then
    echo "beaut: run as root (curl ... | sudo sh)" >&2
    exit 1
fi
TMP=\$(mktemp -d)
trap 'rm -rf "\$TMP"' EXIT HUP INT TERM
curl -fsSL "\$BASE/beaut.tar.gz" -o "\$TMP/beaut.tar.gz"
tar -xzf "\$TMP/beaut.tar.gz" -C "\$TMP"
"\$TMP/install.sh" --roles worker --domain "\$DOMAIN" \
    --admin-port "\$ADMIN_PORT" --tunnel-user "\$TUNNEL_USER" \
    --tunnel-port "\$TUNNEL_PORT" --prefix /usr/local --deps
exec /usr/local/bin/beaut enroll "\$PCT"
EOF
}

# render_client_installer <email> — per-user client install script.
render_client_installer() {
    local email=$1 base token
    base=$(hub_url)
    token=$(client_token_issue "$email") || return 1
    cat <<EOF
#!/bin/sh
# beaut client installer for ${email}
set -eu
BASE='${base}'
DOMAIN='${DOMAIN}'
ADMIN_PORT='${ADMIN_PORT}'
TMP=\$(mktemp -d)
trap 'rm -rf "\$TMP"' EXIT HUP INT TERM
curl -fsSL "\$BASE/beaut.tar.gz" -o "\$TMP/beaut.tar.gz"
tar -xzf "\$TMP/beaut.tar.gz" -C "\$TMP"
"\$TMP/install.sh" --user --roles client --domain "\$DOMAIN" --admin-port "\$ADMIN_PORT"
CONF="\${XDG_CONFIG_HOME:-\$HOME/.config}/beaut/config.env"
umask 077
{
    printf 'CLIENT_TOKEN=%s\n' '${token}'
    printf 'CLIENT_EMAIL=%s\n' '${email}'
} >> "\$CONF"
echo "installed. try: beaut run -- echo hi"
EOF
}
