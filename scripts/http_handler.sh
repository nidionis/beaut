#!/usr/bin/env bash
# http_handler.sh — server-side HTTP handler (one connection per invocation).
# The server never executes work: it serves files/scripts and validates tokens.
#
# Dynamic routes (priority):
#   GET  /work          -> create a token, return it
#   GET  /work/<token>  -> return the command bound to the token
#   POST /done/<token>  -> store the result bound to the token
#   POST /get           -> dataset request (body: key=value&key=value)
#
# Static route (everything else): the URL path mirrors $PUBLISHED_ROOT
#   /a/b/c              -> $PUBLISHED_ROOT/a/b/c            (file)
#   /a/b                -> $PUBLISHED_ROOT/a/b/DEFAU*.sh    (directory -> default)
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/core.sh"
load_config

STATE_DB="$STATE_DIR/db.tsv"
state_init

# --- HTTP responses ---------------------------------------------------------
reason_phrase() {
  case "$1" in
    200) printf 'OK' ;;
    400) printf 'Bad Request' ;;
    403) printf 'Forbidden' ;;
    404) printf 'Not Found' ;;
    410) printf 'Gone' ;;
    *)   printf 'OK' ;;
  esac
}

send_response() {
  local status_code="$1" response_body="${2:-}"
  printf 'HTTP/1.1 %s %s\r\nContent-Length: %s\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n%s' \
    "$status_code" "$(reason_phrase "$status_code")" "${#response_body}" "$response_body"
}

send_file() {
  local file_path="$1" file_size
  file_size="$(wc -c < "$file_path")"
  printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n' "$file_size"
  cat -- "$file_path"
}

# --- request parsing --------------------------------------------------------
# 1. request line: METHOD /path HTTP/1.1
IFS= read -r -t 5 request_line || exit 0
request_line="${request_line%$'\r'}"
http_method="${request_line%% *}"
url_path="${request_line#* }"; url_path="${url_path%% *}"
url_path="${url_path#/}"; url_path="${url_path%%\?*}"

# 2. headers up to the blank line (only Content-Length is kept)
content_length=""
while IFS= read -r -t 5 header; do
  header="${header%$'\r'}"
  [[ -z "$header" ]] && break
  case "${header,,}" in
    content-length:*) content_length="${header#*:}"; content_length="${content_length//[[:space:]]/}" ;;
  esac
done

# 3. raw body for POST only (never a blocking cat on GET)
request_body=""
if [[ "${http_method^^}" == "POST" ]]; then
  if [[ "$content_length" =~ ^[0-9]+$ ]]; then
    IFS= read -r -N "$content_length" request_body || true
  else
    request_body="$(cat)" || true
  fi
fi

# --- form parameter extraction (key=value&key=value) ------------------------
get_form_param() {
  local key="$1"
  printf '%s' "$request_body" | awk -F'[&?]' -v k="$key" '{
    for (i=1;i<=NF;i++) {
      split($i,a,"=")
      if (a[1]==k) { print a[2]; exit }
    }
  }'
}

# --- daily archive of a result ----------------------------------------------
archive_result() {
  local token="$1" result="$2"
  local day; day="$(date +%F)"
  local archive_dir="$STATE_DIR/archive/$day"
  mkdir -p "$archive_dir"

  local total_kb available_kb memory_threshold_kb
  total_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  available_kb="$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  memory_threshold_kb=$(( total_kb / ARCHIVE_MEMORY_DIVISOR ))
  if [[ "$available_kb" -le "$memory_threshold_kb" ]]; then
    log warn "archive skipped: available RAM=${available_kb}KB <= threshold=${memory_threshold_kb}KB"
    return 0
  fi

  local timestamp; timestamp="$(date +%s)"
  local node_name; node_name="$(hostname 2>/dev/null || echo unknown)"
  printf 'archive\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$day" "$token" "$node_name" "$result" "$timestamp" "" "" >> "$STATE_DB"
  printf '%s\t%s\t%s\t%s\n' "$token" "$node_name" "$result" "$timestamp" >> "$archive_dir/results.tsv"
}

# --- static tree ------------------------------------------------------------
find_default_script() {
  local directory="$1" candidate
  for candidate in "$directory"/DEFAU*.sh; do
    if [[ -f "$candidate" ]]; then printf '%s' "$candidate"; return 0; fi
  done
  return 1
}

serve_tree() {
  local requested_path="$1" root_dir real_root target
  root_dir="${PUBLISHED_ROOT:-}"
  if [[ -z "$root_dir" || ! -d "$root_dir" ]]; then
    send_response 404 "${NOT_FOUND_BODY:-404}"; return
  fi
  real_root="$(realpath -m -- "$root_dir" 2>/dev/null || printf '%s' "$root_dir")"

  case "$requested_path" in
    *..*|*\\*) send_response 404 "${NOT_FOUND_BODY:-404}"; return ;;
  esac

  target="$(realpath -m -- "$root_dir/$requested_path" 2>/dev/null || true)"
  if [[ -z "$target" || ( "$target" != "$real_root" && "$target" != "$real_root"/* ) ]]; then
    send_response 404 "${NOT_FOUND_BODY:-404}"; return
  fi

  if [[ -d "$target" ]]; then
    target="$(find_default_script "$target")" \
      || { send_response 404 "${NOT_FOUND_BODY:-404}"; return; }
  fi

  if [[ -f "$target" ]]; then
    send_file "$target"
  else
    send_response 404 "${NOT_FOUND_BODY:-404}"
  fi
}

# --- routing ----------------------------------------------------------------
case "$url_path" in
  work)
    token="$(new_id | tr -d '.')"
    timestamp="$(date +%s)"
    printf 'token\t%s\techo hello-world\tpending\t%s\t\t\t\n' "$token" "$timestamp" >> "$STATE_DB"
    send_response 200 "$token"
    ;;
  work/*)
    token="${url_path#work/}"
    token_row="$(state_find "$STATE_DB" 2 "$token")"
    if [[ -z "$token_row" ]]; then
      send_response 404 "${NOT_FOUND_BODY:-404}"
    else
      row_type="$(printf '%s' "$token_row" | cut -f1)"
      token_status="$(printf '%s' "$token_row" | cut -f4)"
      task_command="$(printf '%s' "$token_row" | cut -f3)"
      if [[ "$row_type" != "token" ]]; then
        send_response 404 "${NOT_FOUND_BODY:-404}"
      elif [[ "$token_status" == "pending" || "$token_status" == "" ]]; then
        send_response 200 "$task_command"
      else
        send_response 410 "token expired or already used ($token_status)"
      fi
    fi
    ;;
  done/*)
    token="${url_path#done/}"
    if [[ -z "$token" ]]; then
      send_response 400 "missing token"
    elif [[ -z "$(state_find "$STATE_DB" 2 "$token")" ]]; then
      send_response 404 "${NOT_FOUND_BODY:-404}"
    else
      archive_result "$token" "$request_body"
      state_update "$STATE_DB" 4 "done" 2 "$token" 2>/dev/null || true
      send_response 200 "confirmed: $token"
    fi
    ;;
  get)
    request_token="$(get_form_param token)"
    dataset="$(get_form_param dataset)"
    if [[ -z "$request_token" ]]; then
      send_response 400 "missing token"
    elif [[ -z "$dataset" ]]; then
      send_response 400 "missing dataset"
    elif [[ -z "$(state_find "$STATE_DB" 2 "$request_token")" ]]; then
      send_response 403 "unknown token"
    else
      send_response 200 "dataset $dataset granted to token $request_token"
    fi
    ;;
  *)
    serve_tree "$url_path"
    ;;
esac
