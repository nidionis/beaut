# http.sh - the tiny HTTP/1.1 request/response layer and listener.

http_request() {
  local method target line
  IFS=' ' read -r method target _ || true
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -z "$line" ]] && break
  done
  printf '%s %s\n' "${method:-GET}" "${target%%\?*}"
}

# http_accept - read one request, set HTTP_PATH and enforce GET/HEAD.
http_accept() {
  local method
  HTTP_HEAD=no
  HTTP_SENT=no
  read -r method HTTP_PATH < <(http_request)
  case "$method" in
    GET) return 0 ;;
    HEAD)
      HTTP_HEAD=yes
      return 0
      ;;
    *)
      http_respond "405 Method Not Allowed" "text/plain" $'method not allowed\n'
      return 1
      ;;
  esac
}

http_respond() {
  local status="$1" type="$2" body="${3:-}" length
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

http_not_found() {
  http_respond "404 Not Found" "text/plain" $'not found\n'
}

html_page() {
  local title="$1" body="$2"
  http_respond "200 OK" "text/html; charset=utf-8" \
    "$(render_template "$BEAUT_ROOT/share/page.html" TITLE "$title" BODY "$body")"
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
    "EXEC:./bin/$program"
}
