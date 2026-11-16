# common.sh - logging, validation and small shared helpers.

log() { printf '[beaut] %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
need_exec() { [[ -x "$1" ]] || die "missing executable: $1"; }

is_uint() { [[ ${1:-} =~ ^[0-9]+$ ]]; }
is_num() { [[ ${1:-} =~ ^[0-9]+([.][0-9]+)?$ ]]; }

# pause SECONDS - sleep without starting an external process.
pause() { read -rt "$1" <> <(:) || :; }

# utc_now - print an ISO 8601 UTC timestamp.
utc_now() { TZ=UTC printf '%(%Y-%m-%dT%H:%M:%SZ)T\n' -1; }

# node_name - print the short host name, using $HOSTNAME when it is set.
node_name() {
  local name="${HOSTNAME:-$(hostname)}"
  printf '%s\n' "${name%%.*}"
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
