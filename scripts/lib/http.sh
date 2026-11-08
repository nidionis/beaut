#!/usr/bin/env bash
# lib/http.sh — HTTP primitives shared by the server handler and the node client:
# response senders, request parsing, form extraction, small client helper.
# Sourced; defines functions only (no side effects).
set -uo pipefail

http_reason_phrase() {
  case "$1" in
    200) printf 'OK' ;;
    400) printf 'Bad Request' ;;
    403) printf 'Forbidden' ;;
    404) printf 'Not Found' ;;
    410) printf 'Gone' ;;
    *)   printf 'OK' ;;
  esac
}

http_send_response() {
  local status_code="$1" response_body="${2:-}"
  printf 'HTTP/1.1 %s %s\r\nContent-Length: %s\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n%s' \
    "$status_code" "$(http_reason_phrase "$status_code")" "${#response_body}" "$response_body"
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

http_send_file() {
  local file_path="$1" file_size content_type
  file_size="$(wc -c < "$file_path")"
  content_type="$(http_content_type_for_file "$file_path")"
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

http_request() {
  # $1 = method (GET|POST), $2 = path, $3 = data (optional, urlencoded)
  # Sets http_status and http_body (no output).
  local method="$1" path="$2" data="${3:-}"
  local tmp
  tmp="$(mktemp)"
  if [[ "$method" == "GET" ]]; then
    http_status="$(curl -s -o "$tmp" -w '%{http_code}' "http://$SERVER_HOST:$HTTP_PORT$path")"
  else
    http_status="$(curl -s -o "$tmp" -w '%{http_code}' -X POST -H 'Content-Type: application/x-www-form-urlencoded' --data "$data" "http://$SERVER_HOST:$HTTP_PORT$path")"
  fi
  http_body="$(cat "$tmp")"
  rm -f -- "$tmp"
}
