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

http_send_file() {
  local file_path="$1" file_size
  file_size="$(wc -c < "$file_path")"
  printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n' "$file_size"
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

http_get_form_param() {
  local key="$1"
  printf '%s' "$request_body" | awk -F'[&?]' -v k="$key" '{
    for (i=1;i<=NF;i++) {
      split($i,a,"=")
      if (a[1]==k) { print a[2]; exit }
    }
  }'
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
