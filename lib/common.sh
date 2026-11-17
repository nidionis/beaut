# common.sh - logging, validation and small shared helpers.

log() {
  local LC_ALL=C
  printf '[beaut %(%H:%M:%S)T] %s\n' -1 "$*" >&2
}

warn() { log "warning: $*"; }
die() { log "error: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
need_exec() { [[ -x "$1" ]] || die "missing executable: $1"; }

is_uint() { [[ ${1:-} =~ ^[0-9]+$ ]]; }
is_num() { [[ ${1:-} =~ ^[0-9]+([.][0-9]+)?$ ]]; }
is_hex() { [[ ${1:-} =~ ^[0-9a-f]+$ ]]; }
is_true() { case "${1:-}" in 1|yes|true|on) return 0 ;; *) return 1 ;; esac; }

# now_epoch - print the current Unix time in seconds.
now_epoch() { printf '%(%s)T\n' -1; }

# pause SECONDS - sleep without starting an external process.
pause() { read -rt "${1:-1}" <> <(:) || :; }

# utc_now - print an ISO 8601 UTC timestamp.
utc_now() { TZ=UTC printf '%(%Y-%m-%dT%H:%M:%SZ)T\n' -1; }

# utc_stamp - print a filename-safe UTC timestamp.
utc_stamp() { TZ=UTC printf '%(%Y%m%dT%H%M%SZ)T\n' -1; }

# node_name - print the short host name, using $HOSTNAME when it is set.
node_name() {
  local name="${HOSTNAME:-$(hostname)}"
  printf '%s\n' "${name%%.*}"
}

# urlhost ADDRESS - bracket an IPv6 literal for use in a URL.
urlhost() {
  local host="$1"
  if [[ "$host" == *:* && "$host" != \[* ]]; then
    printf '[%s]\n' "$host"
  else
    printf '%s\n' "$host"
  fi
}

# api_url ADDRESS PORT PATH - build an internal HTTP URL. There is deliberately
# no localhost fallback anywhere in beaut.
api_url() {
  local address="$1" port="$2" path="${3:-/}"
  printf 'http://%s:%s%s\n' "$(urlhost "$address")" "$port" "$path"
}

# sh_quote VALUE - quote one value for a generated shell script.
sh_quote() {
  local value="$1" out="'" char
  while [[ -n "$value" ]]; do
    char="${value:0:1}"
    value="${value:1}"
    if [[ "$char" == "'" ]]; then
      out+="'\\''"
    else
      out+="$char"
    fi
  done
  printf "%s'" "$out"
}

# url_decode VALUE - decode percent escapes and plus signs in a query value.
url_decode() {
  local value="${1//+/ }"
  printf '%b' "${value//%/\\x}"
}

# worker_hash KEYFILE - first 16 lowercase hex characters of the SHA-256 hash
# of the public key file.
worker_hash() {
  local key="$1"
  [[ -f "$key" && -r "$key" ]] || return 1
  sha256sum -- "$key" | awk '{ print substr($1, 1, 16) }'
}

# hash_text VALUE - short content hash used for local identities.
hash_text() {
  printf '%s' "$1" | sha256sum | awk '{ print substr($1, 1, 16) }'
}

# hash_file FILE - short content hash used for archives and bundles.
hash_file() {
  local file="$1"
  [[ -f "$file" && -r "$file" ]] || return 1
  sha256sum -- "$file" | awk '{ print substr($1, 1, 16) }'
}

# kv_get KEY FILE - read one key=value line through share/awk/kv.awk.
kv_get() {
  local key="$1" file="$2"
  [[ -f "$file" && -r "$file" ]] || return 1
  KV_KEY="$key" awk -f "$BEAUT_ROOT/share/awk/kv.awk" "$file" |
    awk -F '\t' 'NR == 1 { print $2 }'
}

# render_template FILE KEY VALUE [KEY VALUE ...]
#
# Replace @KEY@ markers in FILE. Values are inserted literally, so paths and
# host names do not need shell or sed escaping.
render_template() {
  local file="$1" content key value
  shift

  [[ -f "$file" ]] || die "missing template: $file"
  content="$(<"$file")"

  while (( $# >= 2 )); do
    key="$1"
    value="$2"
    shift 2
    # Bash treats & and \ specially in a replacement string.
    value="${value//\\/\\\\}"
    value="${value//&/\\&}"
    content="${content//@${key}@/$value}"
  done

  printf '%s\n' "$content"
}

# ensure_dir DIR [MODE] - create a directory and optionally set its mode.
ensure_dir() {
  local dir="$1" mode="${2:-}"
  [[ -d "$dir" ]] || mkdir -p -- "$dir" || die "cannot create directory: $dir"
  [[ -n "$mode" ]] && chmod "$mode" -- "$dir"
}

# atomic_write FILE - replace FILE with standard input without partial reads.
atomic_write() {
  local file="$1" dir base tmp
  dir="$(dirname -- "$file")"
  base="$(basename -- "$file")"
  ensure_dir "$dir"
  tmp="$(mktemp "$dir/.$base.XXXXXX")" || die "cannot create temporary file in $dir"
  cat >"$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$file"
}

# read_file FILE - print a file without a subshell when possible.
read_file() {
  local file="$1"
  [[ -f "$file" && -r "$file" ]] || return 1
  printf '%s' "$(<"$file")"
}

# json_escape VALUE - escape a string for a JSON document built by hand. Prefer
# jq -n where a JSON encoder is already required.
json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}
