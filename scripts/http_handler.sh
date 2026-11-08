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
. "$SCRIPT_DIR/lib/http.sh"
load_config

STATE_DB="$STATE_DIR/db.tsv"
state_init

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
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$token" "$node_name" "$result" "$timestamp" >> "$archive_dir/results.tsv"
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
    http_send_response 404 "${NOT_FOUND_BODY:-404}"; return
  fi
  real_root="$(realpath -m -- "$root_dir" 2>/dev/null || printf '%s' "$root_dir")"

  case "$requested_path" in
    *..*|*\\*) http_send_response 404 "${NOT_FOUND_BODY:-404}"; return ;;
  esac

  target="$(realpath -m -- "$root_dir/$requested_path" 2>/dev/null || true)"
  if [[ -z "$target" || ( "$target" != "$real_root" && "$target" != "$real_root"/* ) ]]; then
    http_send_response 404 "${NOT_FOUND_BODY:-404}"; return
  fi

  if [[ -d "$target" ]]; then
    target="$(find_default_script "$target")" \
      || { http_send_response 404 "${NOT_FOUND_BODY:-404}"; return; }
  fi

  if [[ -f "$target" ]]; then
    http_send_file "$target"
  else
    http_send_response 404 "${NOT_FOUND_BODY:-404}"
  fi
}

# --- routing ----------------------------------------------------------------
http_parse_request
[[ -n "${http_method:-}" ]] || exit 0
case "$url_path" in
  work)
    token="$(token_create 'echo hello-world' 'pending' "$(date +%s)")"
    http_send_response 200 "$token"
    ;;
  work/*)
    token="${url_path#work/}"
    if [[ -z "$(token_find "$token")" ]]; then
      http_send_response 404 "${NOT_FOUND_BODY:-404}"
    else
      task_command="$(token_field "$token" 3)"
      token_status="$(token_field "$token" 4)"
      if [[ "$token_status" == "pending" || "$token_status" == "" ]]; then
        http_send_response 200 "$task_command"
      else
        http_send_response 410 "token expired or already used ($token_status)"
      fi
    fi
    ;;
  done/*)
    token="${url_path#done/}"
    if [[ -z "$token" ]]; then
      http_send_response 400 "missing token"
    elif [[ -z "$(token_find "$token")" ]]; then
      http_send_response 404 "${NOT_FOUND_BODY:-404}"
    else
      archive_result "$token" "$request_body"
      state_update "$STATE_DIR/db.tsv" 4 "done" 2 "$token"
      http_send_response 200 "confirmed: $token"
    fi
    ;;
  get)
    request_token="$(http_get_form_param token)"
    dataset="$(http_get_form_param dataset)"
    if [[ -z "$request_token" ]]; then
      http_send_response 400 "missing token"
    elif [[ -z "$dataset" ]]; then
      http_send_response 400 "missing dataset"
    elif [[ -z "$(token_find "$request_token")" ]]; then
      http_send_response 403 "unknown token"
    else
      http_send_response 200 "dataset $dataset granted to token $request_token"
    fi
    ;;
  *)
    serve_tree "$url_path"
    ;;
esac
