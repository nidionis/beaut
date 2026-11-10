#!/usr/bin/env bash
# lib/http.sh — HTTP primitives shared by the server handler and the node client:
# response senders, request parsing, form extraction, small client helper.
# Sourced; defines functions only (no side effects).
set -uo pipefail

http_reason_phrase() {
  case "$1" in
    200) printf 'OK' ;;
    302) printf 'Found' ;;
    400) printf 'Bad Request' ;;
    404) printf 'Not Found' ;;
    409) printf 'Conflict' ;;
    *)   printf 'OK' ;;
  esac
}

http_send_body() {
  local status_code="$1" content_type="$2" response_body="${3:-}"
  printf 'HTTP/1.1 %s %s\r\nContent-Length: %s\r\nContent-Type: %s\r\nConnection: close\r\n\r\n%s' \
    "$status_code" "$(http_reason_phrase "$status_code")" "${#response_body}" "$content_type" "$response_body"
}

http_send_response() {
  http_send_body "$1" 'text/plain; charset=utf-8' "${2:-}"
}

# Pick a content type from the file extension. Scripts and unknown files stay
# text/plain: the platform serves shell code meant for `curl … | sh`, while a
# site tree can also contain real HTML, stylesheets, Markdown and images.
http_content_type_for_file() {
  local file_path="${1:-}" extension
  extension="${file_path##*/}"
  if [[ "$extension" == *.* ]]; then
    extension="${extension##*.}"
  else
    extension=""
  fi
  case "${extension,,}" in
    html|htm)   printf 'text/html; charset=utf-8' ;;
    css)        printf 'text/css; charset=utf-8' ;;
    js|mjs)     printf 'application/javascript; charset=utf-8' ;;
    json)       printf 'application/json; charset=utf-8' ;;
    md|markdown) printf 'text/markdown; charset=utf-8' ;;
    svg)        printf 'image/svg+xml' ;;
    png)        printf 'image/png' ;;
    jpg|jpeg)   printf 'image/jpeg' ;;
    gif)        printf 'image/gif' ;;
    webp)       printf 'image/webp' ;;
    ico)        printf 'image/x-icon' ;;
    pdf)        printf 'application/pdf' ;;
    wasm)       printf 'application/wasm' ;;
    *)          printf 'text/plain; charset=utf-8' ;;
  esac
}

# Escape a value for an HTML text node or attribute.
http_html_escape() {
  local value="${1:-}"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  printf '%s' "$value"
}

# Render {{NAME}} placeholders from configuration. Only public deployment
# values are substituted; everything else in the file is left byte-for-byte.
http_render_variables() {
  local file_path="$1" content variable value
  IFS= read -r -d '' content < "$file_path" || true
  for variable in SERVER_HOST HTTP_PORT SERVICE_USER WG_PORT WG_NETWORK WG_SERVER_IP; do
    value="${!variable:-}"
    [[ -n "$value" ]] || continue
    content="${content//"{{$variable}}"/$value}"
  done
  printf '%s' "$content"
}

http_file_is_text() {
  case "$1" in
    text/html*|text/css*|text/markdown*|application/javascript*|application/json*|image/svg+xml) return 0 ;;
    *) return 1 ;;
  esac
}

# serve_mode: "render" substitutes {{NAME}}; "raw" streams the file unchanged.
http_send_file() {
  local file_path="$1" serve_mode="${2:-render}"
  local content_type body file_size
  content_type="$(http_content_type_for_file "$file_path")"
  if [[ "$serve_mode" == "render" ]] && http_file_is_text "$content_type"; then
    body="$(http_render_variables "$file_path")"
    http_send_body 200 "$content_type" "$body"
    return
  fi
  file_size="$(wc -c < "$file_path")"
  printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\nContent-Type: %s\r\nConnection: close\r\n\r\n' \
    "$file_size" "$content_type"
  cat -- "$file_path"
}

http_parse_request() {
  # Fills: http_method, url_path, content_length, request_body
  IFS= read -r -t 5 request_line || return 0
  request_line="${request_line%$'\r'}"
  http_method="${request_line%% *}"
  url_path="${request_line#* }"; url_path="${url_path%% *}"
  url_path="${url_path#/}"; url_path="${url_path%%\?*}"
  content_length=""
  while IFS= read -r -t 5 header; do
    header="${header%$'\r'}"
    [[ -z "$header" ]] && break
    case "${header,,}" in
      content-length:*) content_length="${header#*:}"; content_length="${content_length//[[:space:]]/}" ;;
    esac
  done
  request_body=""
  if [[ "${http_method^^}" == "POST" ]]; then
    if [[ "$content_length" =~ ^[0-9]+$ ]]; then
      IFS= read -r -N "$content_length" request_body || true
    else
      request_body="$(cat)" || true
    fi
  fi
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
          # NUL cannot be represented in a bash string; every other byte can.
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

# Extract one application/x-www-form-urlencoded field. Values may contain '='
# (WireGuard public keys end with one), so only the first '=' is a separator.
http_get_form_param() {
  local wanted_key="${1:-}" pair key value remaining
  remaining="${request_body:-}"
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
    if [[ "$key" == "$wanted_key" ]]; then
      http_url_decode "$value"
      return 0
    fi
  done
  return 1
}

# Call the control server and set http_status and http_body. Extra arguments
# are passed to curl (for example --data-urlencode field=value).
http_request() {
  local method="$1" path="$2"; shift 2
  local response_file
  response_file="$(mktemp)"
  http_status="$(curl -s -o "$response_file" -w '%{http_code}' -X "$method" \
    "$@" "http://$SERVER_HOST:$HTTP_PORT$path")"
  http_body="$(cat "$response_file")"
  rm -f -- "$response_file"
}
