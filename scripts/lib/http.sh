#!/usr/bin/env bash
# lib/http.sh — clients HTTP pur bash via /dev/tcp
# Pas de dépendance à curl/wget/socat.
set -uo pipefail

# http_post <host> <port> <path> <body>
# Envoie une requête POST et affiche la réponse brute sur stdout.
http_post() {
  local host="$1" port="$2" path="$3" body="$4"
  local clen=${#body}
  exec 3<>/dev/tcp/"$host"/"$port" || { echo "ERR_CONNECT $host:$port"; return 1; }
  printf 'POST %s HTTP/1.1\r\nHost: %s:%s\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
    "$path" "$host" "$port" "$clen" "$body" >&3
  local resp
  resp="$(cat <&3)"
  exec 3>&-
  printf '%s' "$resp"
}

# http_get <host> <port> <path>
# Envoie une requête GET et affiche la réponse brute sur stdout.
http_get() {
  local host="$1" port="$2" path="$3"
  exec 3<>/dev/tcp/"$host"/"$port" || { echo "ERR_CONNECT $host:$port"; return 1; }
  printf 'GET %s HTTP/1.1\r\nHost: %s:%s\r\nConnection: close\r\n\r\n' \
    "$path" "$host" "$port" >&3
  local resp
  resp="$(cat <&3)"
  exec 3>&-
  printf '%s' "$resp"
}
