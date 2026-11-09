#!/usr/bin/env bash
# http_handler.sh — server-side HTTP handler (one connection per invocation).
# The server never executes work: it serves files/scripts and validates tokens.
#
# Dynamic routes (priority):
#   GET  /work          -> return an id and the command (from $SVR_ROOT/command)
#   GET  /work/<id>     -> return the command
#   POST /done/<id>     -> archive the posted result
#   POST /get           -> dataset request (body: key=value&key=value)
#   GET  /signin        -> enrollment instructions
#   POST /signin        -> accept a device public key (invite auto-accepts)
#   GET  /signin/<id>   -> device status
#   GET  /door          -> default server public key and WireGuard endpoint
#
# Static routes (everything else): the URL path mirrors a root directory.
#   /a/b/c              -> $PUBLISHED_ROOT/a/b/c            (file)
#   /a/b                -> $PUBLISHED_ROOT/a/b/index.html  (page)
#                       -> $PUBLISHED_ROOT/a/b/DEFAU*.sh   (script fallback)
# Dot-prefixed path segments are never served, so `.git` stays private.
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/core.sh"
. "$SCRIPT_DIR/lib/http.sh"
. "$SCRIPT_DIR/lib/devices.sh"
. "$SCRIPT_DIR/lib/invites.sh"
. "$SCRIPT_DIR/lib/personal_tree.sh"
load_config

STATE_DB="$STATE_DIR/db.tsv"
state_init

not_found() {
  http_send_response 404 "${NOT_FOUND_BODY:-404}"
}

# --- daily archive of a result ----------------------------------------------
archive_result() {
  local token="$1" result="$2"
  local day; day="$(date +%F)"
  local archive_dir="$STATE_DIR/archive/$day"
  mkdir -p "$archive_dir"

  local total_kb=0 available_kb=0 memory_threshold_kb
  read -r total_kb available_kb < <(
    awk '/MemTotal/{total=$2} /MemAvailable/{available=$2} END{print total+0, available+0}' \
      /proc/meminfo 2>/dev/null
  )
  memory_threshold_kb=$(( total_kb / ARCHIVE_MEMORY_DIVISOR ))
  if [[ "$available_kb" -le "$memory_threshold_kb" ]]; then
    log warn "archive skipped: available RAM=${available_kb}KB <= threshold=${memory_threshold_kb}KB"
    return 0
  fi

  local timestamp; timestamp="$(date +%s)"
  local node_name; node_name="$(hostname 2>/dev/null || echo unknown)"
  state_append "$STATE_DB" archive "$day" "$token" "$node_name" "$result" "$timestamp" "" ""
  state_append "$archive_dir/results.tsv" "$token" "$node_name" "$result" "$timestamp" "" "" "" ""
}

# --- static tree ------------------------------------------------------------
# A directory prefers a real index page; DEFAU*.sh remains the script default.
find_default_file() {
  local directory="$1" candidate
  for candidate in "$directory/index.html" "$directory/index.htm" "$directory"/DEFAU*.sh; do
    if [[ -f "$candidate" ]]; then printf '%s' "$candidate"; return 0; fi
  done
  return 1
}

# Reject any path with a dot-prefixed segment: hidden files and `.git` must not
# be reachable over HTTP, even inside a site repository.
path_has_hidden_segment() {
  [[ "/${1:-}/" == */.* ]]
}

# Browse a directory that has neither an index page nor a DEFAULT script.
serve_directory_index() {
  local directory="$1" request_path="$2"
  local body entry name suffix
  body='<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Index of /'"$(http_html_escape "$request_path")"'</title>
<link rel="stylesheet" href="/style.css">
</head><body><main>
<h1>Index of /'"$(http_html_escape "$request_path")"'</h1>
<ul>'
  [[ -z "$request_path" ]] || body+='<li><a href="../">../</a></li>'
  while IFS= read -r -d '' entry; do
    name="${entry##*/}"
    [[ "$name" == .* ]] && continue
    suffix=""
    [[ -d "$entry" ]] && suffix="/"
    body+='<li><a href="'"$(http_html_escape "$name")$suffix"'">'"$(http_html_escape "$name")$suffix"'</a></li>'
  done < <(find "$directory" -mindepth 1 -maxdepth 1 -print0 | LC_ALL=C sort -z)
  body+='</ul>
</main></body></html>'
  http_send_body 200 'text/html; charset=utf-8' "$body"
}

serve_tree() {
  local requested_path="$1" root_directory="${2:-${PUBLISHED_ROOT:-}}"
  local serve_mode="${3:-render}" extra_root="${4:-}"
  local real_root real_extra target directory
  if [[ -z "$root_directory" || ! -d "$root_directory" ]]; then
    not_found; return
  fi
  real_root="$(realpath -m -- "$root_directory" 2>/dev/null || printf '%s' "$root_directory")"
  real_extra=''
  if [[ -n "$extra_root" && -d "$extra_root" ]]; then
    real_extra="$(realpath -m -- "$extra_root" 2>/dev/null || printf '%s' "$extra_root")"
  fi

  case "$requested_path" in
    *..*|*\\*) not_found; return ;;
  esac
  path_has_hidden_segment "$requested_path" && { not_found; return; }

  target="$(realpath -m -- "$root_directory/$requested_path" 2>/dev/null || true)"
  if [[ -z "$target" ]]; then
    not_found; return
  fi
  # The target must stay inside the served root, an explicit extra root, or
  # the configured personal tree root (SVR_NAME symlink target).
  if [[ "$target" != "$real_root" && "$target" != "$real_root"/* ]]; then
    local allowed_extra="$real_extra" svr_real=""
    if declare -F personal_tree_root >/dev/null 2>&1; then
      svr_real="$(realpath -m -- "$(personal_tree_root 2>/dev/null)" 2>/dev/null || true)"
    fi
    if [[ -z "$allowed_extra" && -n "$svr_real" ]] || [[ -n "$svr_real" && ( "$target" == "$svr_real" || "$target" == "$svr_real"/* ) ]]; then
      : # allowed via svr root
    elif [[ -n "$allowed_extra" && ( "$target" == "$allowed_extra" || "$target" == "$allowed_extra"/* ) ]]; then
      : # allowed
    elif [[ -n "$svr_real" && ( "$target" == "$svr_real" || "$target" == "$svr_real"/* ) ]]; then
      :
    else
      not_found; return
    fi
  fi

  if [[ -d "$target" ]]; then
    directory="$target"
    if ! target="$(find_default_file "$directory")"; then
      serve_directory_index "$directory" "$requested_path"
      return
    fi
  fi

  if [[ -f "$target" ]]; then
    http_send_file "$target" "$serve_mode"
  else
    not_found
  fi
}

# --- device enrollment -------------------------------------------------------
device_name_sanitize() {
  local name="${1:-device}"
  name="${name//$'\t'/ }"
  name="${name//$'\n'/ }"
  name="${name//\//-}"
  name="${name:0:64}"
  [[ -n "$name" ]] || name="device"
  printf '%s' "$name"
}

enroll_device() {
  local public_key device_name pass_message response
  public_key="$(http_get_form_param public_key || true)"
  device_name="$(http_get_form_param device_name || true)"
  pass_message="$(http_get_form_param pass_message || true)"

  if [[ -z "$public_key" ]]; then
    http_send_response 400 "missing public_key"; return
  fi
  if ! device_validate_public_key "$public_key"; then
    http_send_response 400 "invalid public_key"; return
  fi

  response="$(device_enroll "$(device_name_sanitize "$device_name")" "$public_key" "$pass_message")" || {
    http_send_response 400 "cannot enroll device"
    return
  }
  http_send_response 200 "$response"
}

serve_device_status() {
  local row
  row="$(device_find "$1")" || { not_found; return; }
  [[ -n "$row" ]] || { not_found; return; }
  http_send_response 200 "$(device_print_response "$row")"
}

serve_door() {
  local door_id row
  door_id="$(device_default_door_id || true)"
  if [[ -z "$door_id" ]]; then
    http_send_response 404 "no approved door"
    return
  fi
  row="$(device_find "$door_id")" || {
    http_send_response 404 "no approved door"; return
  }
  http_send_response 200 "$(printf 'public_key=%s\nendpoint=%s:%s\nnetwork=%s\nserver_address=%s' \
    "$(state_field "$row" 3)" "$SERVER_HOST" "$WG_PORT" "$WG_NETWORK" \
    "$(state_field "$row" 4)")"
}

# --- routing ----------------------------------------------------------------
http_parse_request
[[ -n "${http_method:-}" ]] || exit 0
# Command served to workers: $SVR_ROOT/command, else a safe default.
work_command() {
  local cmd_file
  if declare -F personal_tree_root >/dev/null 2>&1; then
    cmd_file="$(personal_tree_root 2>/dev/null)/command"
    [[ -f "$cmd_file" ]] && { cat -- "$cmd_file"; return; }
  fi
  printf 'echo hello-world\n'
}

case "$url_path" in
  work)
    token="$(date +%s%N 2>/dev/null || echo "$$.$(date +%s)").$RANDOM"
    http_send_response 200 "$token"
    ;;
  work/*)
    token="${url_path#work/}"
    if [[ -z "$token" ]]; then
      http_send_response 400 "missing id"
    else
      http_send_response 200 "$(work_command)"
    fi
    ;;
  done/*)
    token="${url_path#done/}"
    if [[ -z "$token" ]]; then
      http_send_response 400 "missing id"
    else
      archive_result "$token" "$request_body"
      http_send_response 200 "confirmed: $token"
    fi
    ;;
  get)
    dataset="$(http_get_form_param dataset)"
    if [[ -z "$dataset" ]]; then
      http_send_response 400 "missing dataset"
    else
      http_send_response 200 "dataset $dataset granted"
    fi
    ;;
  signin)
    if [[ "${http_method^^}" == "POST" ]]; then
      enroll_device
    else
      http_send_response 200 "POST public_key, device_name and optional pass_message to enroll this device"
    fi
    ;;
  signin/*)
    serve_device_status "${url_path#signin/}"
    ;;
  door)
    serve_door
    ;;
  *)
    _svr_name=""
    if declare -F personal_tree_name >/dev/null 2>&1; then _svr_name="$(personal_tree_name 2>/dev/null || true)"; fi
    if [[ -n "$_svr_name" && ( "$url_path" == "$_svr_name" || "$url_path" == "$_svr_name"/* ) ]]; then
      serve_tree "$url_path" "${PUBLISHED_ROOT:-}" raw
    else
      serve_tree "$url_path"
    fi
    ;;
esac
