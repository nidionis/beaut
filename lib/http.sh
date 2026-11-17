# http.sh - the tiny HTTP/1.1 request/response layer and listener.

# http_accept - read one request, set HTTP_METHOD, HTTP_PATH, HTTP_QUERY,
# HTTP_HEAD, HTTP_BODY_FILE and HTTP_BODY_LEN. POST and PUT bodies are stored in
# a temporary file so route scripts can inspect or move them atomically.
http_accept() {
  local method target version line name value length=0
  HTTP_HEAD=no
  HTTP_SENT=no
  HTTP_METHOD=""
  HTTP_PATH=""
  HTTP_QUERY=""
  HTTP_BODY_FILE=""
  HTTP_BODY_LEN=0

  IFS=' ' read -r method target version || return 1
  method="${method%$'\r'}"
  target="${target%$'\r'}"
  version="${version%$'\r'}"

  [[ -n "$method" && -n "$target" ]] || return 1
  [[ "$target" == /* ]] || {
    http_respond "400 Bad Request" "text/plain" $'bad request target\n'
    return 1
  }

  HTTP_METHOD="$method"
  [[ "$method" == HEAD ]] && HTTP_HEAD=yes
  HTTP_PATH="${target%%\?*}"
  if [[ "$target" == *\?* ]]; then
    HTTP_QUERY="${target#*\?}"
  fi

  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -z "$line" ]] && break
    name="${line%%:*}"
    value="${line#*:}"
    value="${value# }"
    case "${name,,}" in
      content-length)
        value="${value//[^0-9]/}"
        [[ -n "$value" ]] && length="$value"
        ;;
    esac
  done

  if (( length > HTTP_MAX_BODY )); then
    http_respond "413 Payload Too Large" "text/plain" $'request body too large\n'
    return 1
  fi

  case "$method" in
    GET|HEAD) ;;
    POST|PUT)
      HTTP_BODY_FILE="$(mktemp "${TMPDIR:-/tmp}/beaut-body.XXXXXX")" ||
        {
          http_respond "500 Internal Server Error" "text/plain" $'cannot store request body\n'
          return 1
        }
      HTTP_BODY_LEN="$length"
      if (( length > 0 )); then
        if ! head -c "$length" >"$HTTP_BODY_FILE"; then
          rm -f -- "$HTTP_BODY_FILE"
          HTTP_BODY_FILE=""
          http_respond "400 Bad Request" "text/plain" $'cannot read request body\n'
          return 1
        fi
      fi
      ;;
    *)
      http_respond "405 Method Not Allowed" "text/plain" $'method not allowed\n'
      return 1
      ;;
  esac

  return 0
}

# http_cleanup - remove the temporary body file after the route is done.
http_cleanup() {
  [[ -n "${HTTP_BODY_FILE:-}" && -f "$HTTP_BODY_FILE" ]] && rm -f -- "$HTTP_BODY_FILE"
  HTTP_BODY_FILE=""
}

http_respond() {
  local status="$1" type="$2" body="${3-}" length
  local LC_ALL=C
  HTTP_SENT=yes
  length=${#body}
  if [[ "${HTTP_HEAD:-no}" == yes ]]; then
    printf 'HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %s\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n' \
      "$status" "$type" "$length"
    return
  fi
  printf 'HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %s\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n%s' \
    "$status" "$type" "$length" "$body"
}

# http_send_file FILE CONTENT_TYPE - stream a file without loading it in memory.
http_send_file() {
  local file="$1" type="$2" size
  [[ -f "$file" && -r "$file" ]] || {
    http_not_found
    return
  }
  size="$(stat -c %s -- "$file")" || {
    http_respond "500 Internal Server Error" "text/plain" $'cannot stat file\n'
    return
  }
  HTTP_SENT=yes
  printf 'HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %s\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n' \
    "$type" "$size"
  [[ "${HTTP_HEAD:-no}" == yes ]] || cat -- "$file"
}

http_not_found() {
  http_respond "404 Not Found" "text/plain" $'not found\n'
}

http_forbidden() {
  http_respond "403 Forbidden" "text/plain" $'forbidden\n'
}

http_json() {
  local status="$1" body="$2"
  http_respond "$status" "application/json" "$body"$'\n'
}

# http_query_get KEY - read one key from the request query string.
http_query_get() {
  local key="$1" value
  [[ -n "${HTTP_QUERY:-}" ]] || return 1
  value="$(printf '%s\n' "${HTTP_QUERY//&/$'\n'}" |
    KV_KEY="$key" awk -f "$BEAUT_ROOT/share/awk/kv.awk" |
    awk -F '\t' 'NR == 1 { print $2 }')"
  [[ -n "$value" ]] || return 1
  url_decode "$value"
}

# http_param KEY - query first, then an x-www-form-urlencoded body.
http_param() {
  local key="$1" value
  if value="$(http_query_get "$key")"; then
    printf '%s\n' "$value"
    return 0
  fi
  [[ -n "${HTTP_BODY_FILE:-}" && -f "$HTTP_BODY_FILE" ]] || return 1
  value="$(tr '&' '\n' <"$HTTP_BODY_FILE" |
    KV_KEY="$key" awk -f "$BEAUT_ROOT/share/awk/kv.awk" |
    awk -F '\t' 'NR == 1 { print $2 }')"
  [[ -n "$value" ]] || return 1
  url_decode "$value"
}

# http_body_text - print the request body.
http_body_text() {
  [[ -n "${HTTP_BODY_FILE:-}" && -f "$HTTP_BODY_FILE" ]] && cat -- "$HTTP_BODY_FILE"
}

# http_listen NAME PORT BIND PROGRAM - run a socat HTTP listener.
http_listen() {
  local name="$1" port="$2" bind="$3" program="$4"
  need socat
  is_uint "$port" || die "invalid $name port: $port"
  [[ -n "$bind" ]] || bind=0.0.0.0

  cd "$BEAUT_ROOT" || die "cannot enter $BEAUT_ROOT"
  log "$name listening on ${bind}:${port}"
  exec socat "TCP-LISTEN:${port},bind=${bind},fork,reuseaddr" \
    "EXEC:${BEAUT_ROOT}/bin/${program}"
}
