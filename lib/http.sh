#!/usr/bin/env bash
# http.sh - HTTP parsing, responses, proxying and static files.
# Works with a binary request body by keeping it in HTTP_BODY_FILE.

HTTP_METHOD=""
HTTP_PATH=""
HTTP_QUERY=""
HTTP_VERSION=""
HTTP_BODY_FILE=""
declare -gA HTTP_HEADERS=()

# Status reasons are data, not control flow: they live in the protected
# defaults as BEAUT_HTTP_REASONS.  Unknown statuses fall back to one default.
http_reason() {
  local status="${1:-0}"
  printf '%s' "${BEAUT_HTTP_REASONS[$status]:-${BEAUT_HTTP_REASON_DEFAULT:-OK}}"
}

http_url_decode() {
  local encoded="${1:-}" decoded="" character hex
  while [[ -n "$encoded" ]]; do
    character="${encoded:0:1}"
    encoded="${encoded:1}"
    case "$character" in
      '+')
        decoded+=" "
        ;;
      '%')
        hex="${encoded:0:2}"
        if [[ "$hex" =~ ^[0-9A-Fa-f]{2}$ ]]; then
          if [[ "$hex" != "00" ]]; then
            printf -v character '%b' "\\x$hex"
            decoded+="$character"
          fi
          encoded="${encoded:2}"
        else
          decoded+="%"
        fi
        ;;
      *)
        decoded+="$character"
        ;;
    esac
  done
  printf '%s' "$decoded"
}

http_parse_request() {
  local request_line header key value length
  IFS= read -r -t 10 request_line || return 1
  request_line="${request_line%$'\r'}"
  [[ -n "$request_line" ]] || return 1

  HTTP_METHOD="${request_line%% *}"
  local rest="${request_line#* }"
  HTTP_VERSION="${rest##* }"
  local target="${rest% *}"
  HTTP_PATH="${target%%\?*}"
  HTTP_PATH="${HTTP_PATH#/}"
  if [[ "$target" == *"?"* ]]; then
    HTTP_QUERY="${target#*\?}"
  else
    HTTP_QUERY=""
  fi

  HTTP_HEADERS=()
  while IFS= read -r -t 10 header; do
    header="${header%$'\r'}"
    [[ -z "$header" ]] && break
    key="${header%%:*}"
    value="${header#*:}"
    value="${value#"${value%%[![:space:]]*}"}"
    key="${key,,}"
    HTTP_HEADERS["$key"]="$value"
  done

  HTTP_BODY_FILE="$(mktemp "${TMPDIR:-/tmp}/beaut-body.XXXXXX")" || return 1
  length="${HTTP_HEADERS[content-length]:-0}"
  if [[ "$length" =~ ^[0-9]+$ ]] && (( length > 0 )); then
    if (( length > BEAUT_MAX_BODY )); then
      return 2
    fi
    head -c "$length" > "$HTTP_BODY_FILE" || return 1
  fi
  return 0
}

http_header() {
  local name="${1,,}"
  printf '%s' "${HTTP_HEADERS[$name]:-}"
}

http_query_param() {
  local wanted="${1:-}" remaining="${HTTP_QUERY:-}" pair key value
  while [[ -n "$remaining" ]]; do
    pair="${remaining%%&*}"
    if [[ "$remaining" == *"&"* ]]; then
      remaining="${remaining#*&}"
    else
      remaining=""
    fi
    key="${pair%%=*}"
    if [[ "$pair" == *"="* ]]; then
      value="${pair#*=}"
    else
      value=""
    fi
    key="$(http_url_decode "$key")"
    if [[ "$key" == "$wanted" ]]; then
      http_url_decode "$value"
      return 0
    fi
  done
  return 1
}

http_form_param() {
  local wanted="${1:-}" content="${2:-}" pair key value
  content="${content//$'\r'/}"
  content="${content//$'\n'/&}"
  while [[ -n "$content" ]]; do
    pair="${content%%&*}"
    if [[ "$content" == *"&"* ]]; then
      content="${content#*&}"
    else
      content=""
    fi
    key="${pair%%=*}"
    if [[ "$pair" == *"="* ]]; then
      value="${pair#*=}"
    else
      value=""
    fi
    key="$(http_url_decode "$key")"
    if [[ "$key" == "$wanted" ]]; then
      http_url_decode "$value"
      return 0
    fi
  done
  return 1
}

http_body_text() {
  [[ -n "${HTTP_BODY_FILE:-}" && -f "$HTTP_BODY_FILE" ]] && cat -- "$HTTP_BODY_FILE"
}

http_body_json() {
  [[ -n "${HTTP_BODY_FILE:-}" && -f "$HTTP_BODY_FILE" ]] || return 1
  jq -e . "$HTTP_BODY_FILE" 2>/dev/null
}

http_send_headers() {
  local status="$1" content_type="$2" content_length="$3"; shift 3
  printf 'HTTP/1.1 %s %s\r\n' "$status" "$(http_reason "$status")"
  printf 'Content-Type: %s\r\n' "$content_type"
  printf 'Content-Length: %s\r\n' "$content_length"
  printf 'Connection: close\r\n'
  printf 'X-Content-Type-Options: nosniff\r\n'
  printf 'X-Beaut-Version: %s\r\n' "${BEAUT_VERSION:-unknown}"
  local header
  for header in "$@"; do
    printf '%s\r\n' "$header"
  done
  printf '\r\n'
}

http_respond() {
  local status="$1" content_type="${2:-text/plain; charset=utf-8}" body="${3:-}"
  http_send_headers "$status" "$content_type" "${#body}"
  [[ "${HTTP_METHOD^^}" == "HEAD" ]] || printf '%s' "$body"
}

http_respond_json() {
  local status="$1" body="$2"
  http_send_headers "$status" 'application/json; charset=utf-8' "${#body}"
  [[ "${HTTP_METHOD^^}" == "HEAD" ]] || printf '%s' "$body"
}

http_respond_error() {
  local status="$1" message="$2"
  local body
  body="$(jq -cn --arg error "$message" '{ok:false,error:$error}')"
  http_respond_json "$status" "$body"
}

http_respond_file() {
  local path="$1" content_type="${2:-$(http_content_type "$1")}" size
  [[ -f "$path" ]] || {
    http_respond_error "$BEAUT_HTTP_NOT_FOUND" "$BEAUT_MSG_NOT_FOUND"
    return
  }
  size="$(beaut_file_size "$path")"
  http_send_headers "$BEAUT_HTTP_OK" "$content_type" "$size"
  [[ "${HTTP_METHOD^^}" == "HEAD" ]] || cat -- "$path"
}

http_content_type() {
  local name="${1:-}" ext
  ext="${name##*/}"
  if [[ "$ext" == *.* ]]; then ext="${ext##*.}"; else ext=""; fi
  case "${ext,,}" in
    html|htm) printf 'text/html; charset=utf-8' ;;
    css) printf 'text/css; charset=utf-8' ;;
    js|mjs) printf 'application/javascript; charset=utf-8' ;;
    json) printf 'application/json; charset=utf-8' ;;
    md) printf 'text/markdown; charset=utf-8' ;;
    txt|log|conf) printf 'text/plain; charset=utf-8' ;;
    svg) printf 'image/svg+xml' ;;
    png) printf 'image/png' ;;
    jpg|jpeg) printf 'image/jpeg' ;;
    gif) printf 'image/gif' ;;
    webp) printf 'image/webp' ;;
    ico) printf 'image/x-icon' ;;
    wasm) printf 'application/wasm' ;;
    tar) printf 'application/x-tar' ;;
    gz) printf 'application/gzip' ;;
    zst) printf 'application/zstd' ;;
    *) printf 'application/octet-stream' ;;
  esac
}

http_serve_static() {
  local root="$1" requested="$2" target real_root directory
  [[ -d "$root" ]] || {
    http_respond_error "$BEAUT_HTTP_NOT_FOUND" "$BEAUT_MSG_NOT_FOUND"
    return
  }
  case "$requested" in
    *..*|*\\*|*//*) http_respond_error "$BEAUT_HTTP_NOT_FOUND" "$BEAUT_MSG_NOT_FOUND"; return ;;
  esac
  [[ "/${requested}/" == */.* ]] && {
    http_respond_error "$BEAUT_HTTP_NOT_FOUND" "$BEAUT_MSG_NOT_FOUND"
    return
  }
  real_root="$(realpath -m -- "$root")"
  target="$(realpath -m -- "${root%/}/${requested}")"
  [[ "$target" == "$real_root" || "$target" == "$real_root"/* ]] || {
    http_respond_error "$BEAUT_HTTP_NOT_FOUND" "$BEAUT_MSG_NOT_FOUND"
    return
  }
  if [[ -d "$target" ]]; then
    directory="$target"
    if [[ -f "$directory/index.html" ]]; then
      target="$directory/index.html"
    elif [[ -f "$directory/index.htm" ]]; then
      target="$directory/index.htm"
    else
      http_respond_error "$BEAUT_HTTP_NOT_FOUND" "$BEAUT_MSG_NOT_FOUND"
      return
    fi
  fi
  [[ -f "$target" ]] || {
    http_respond_error "$BEAUT_HTTP_NOT_FOUND" "$BEAUT_MSG_NOT_FOUND"
    return
  }
  http_respond_file "$target"
}

http_stream_file() {
  local path="$1" content_type="${2:-application/octet-stream}"
  local size
  size="$(beaut_file_size "$path")"
  http_send_headers "$BEAUT_HTTP_OK" "$content_type" "$size"
  [[ "${HTTP_METHOD^^}" == "HEAD" ]] || cat -- "$path"
}

# Forward the current request to an HTTP worker.  This is deliberately a
# request/response proxy; raw TCP and WebSocket routes are handled by
# `beaut router` and a stream-capable proxy in a later layer.
http_proxy_http() {
  local target_url="$1" tmp result
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/beaut-proxy.XXXXXX")" || {
    http_respond_error "$BEAUT_HTTP_INTERNAL_SERVER_ERROR" "proxy temp failure"
    return 1
  }
  _http_proxy_http_work "$target_url" "$tmp"
  result=$?
  rm -rf -- "$tmp"
  return "$result"
}

_http_proxy_http_work() {
  local target_url="$1" tmp="$2" method="${HTTP_METHOD^^}" status content_type body
  local -a curl_args

  curl_args=(-sS --connect-timeout 3 --max-time "$BEAUT_PROXY_TIMEOUT"
    --dump-header "$tmp/headers" --output "$tmp/body" --request "$method")
  local header value
  for header in host content-type accept accept-language accept-encoding authorization cookie range user-agent origin referer if-none-match if-modified-since x-requested-with; do
    value="${HTTP_HEADERS[$header]:-}"
    [[ -n "$value" ]] && curl_args+=(-H "$header: $value")
  done
  if [[ -n "${HTTP_BODY_FILE:-}" && -s "$HTTP_BODY_FILE" ]]; then
    curl_args+=(--data-binary "@$HTTP_BODY_FILE")
  fi
  if [[ "$method" == "HEAD" ]]; then
    curl_args+=(--head)
  fi

  if ! curl "${curl_args[@]}" "$target_url" >/dev/null 2>&1; then
    http_respond_error "$BEAUT_HTTP_BAD_GATEWAY" "$BEAUT_MSG_UPSTREAM_UNREACHABLE"
    return
  fi

  status="$(awk 'toupper($1) ~ /^HTTP/ {code=$2} END {print code+0}' "$tmp/headers")"
  [[ "$status" =~ ^[0-9]+$ ]] && (( status >= 100 )) || status="$BEAUT_HTTP_BAD_GATEWAY"
  content_type="$(awk 'BEGIN{IGNORECASE=1} /^content-type:/ {sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit}' "$tmp/headers")"
  [[ -n "$content_type" ]] || content_type="$(http_content_type "$target_url")"
  body="$tmp/body"

  local -a response_headers=()
  local name
  for name in cache-control content-encoding content-language etag last-modified location content-disposition www-authenticate; do
    local line
    line="$(awk -v n="$name" 'BEGIN{IGNORECASE=1} tolower($0) ~ "^" n ":" {sub(/\r$/, ""); print; exit}' "$tmp/headers")"
    [[ -n "$line" ]] && response_headers+=("$line")
  done
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[Ss]et-[Cc]ookie: ]] && response_headers+=("$line")
  done < <(grep -i '^set-cookie:' "$tmp/headers" 2>/dev/null || true)

  http_send_headers "$status" "$content_type" "$(beaut_file_size "$body")" "${response_headers[@]}"
  if [[ "$method" != "HEAD" ]]; then
    cat -- "$body"
  fi
}

# Proxy a package download chunk-by-chunk without staging the whole package.
# The argument is the manifest JSON itself, not a file path.
http_stream_package() {
  local manifest="$1" chunk hex chunk_path
  local -a chunks
  mapfile -t chunks < <(jq -r '.chunks[]?' <<<"$manifest")
  # Never announce a length we cannot satisfy: check every object first.
  for chunk in "${chunks[@]}"; do
    hex="${chunk#sha256:}"
    chunk_path="${BEAUT_STORE_DIR}/objects/${hex:0:2}/${hex}"
    [[ -f "$chunk_path" ]] || return 1
  done
  http_send_headers "$BEAUT_HTTP_OK" 'application/octet-stream' "$(jq -r '.size' <<<"$manifest")"
  if [[ "${HTTP_METHOD^^}" == "HEAD" ]]; then
    return
  fi
  for chunk in "${chunks[@]}"; do
    hex="${chunk#sha256:}"
    chunk_path="${BEAUT_STORE_DIR}/objects/${hex:0:2}/${hex}"
    cat -- "$chunk_path"
  done
}
