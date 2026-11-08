#!/usr/bin/env bash
# http_handler.sh — server-side HTTP handler (one connection per invocation).
# The server never executes work: it serves files/scripts and validates tokens.
#
# Dynamic routes (priority):
#   GET  /work          -> create a token, return it
#   GET  /work/<token>  -> return the command bound to the token
#   POST /done/<token>  -> store the result bound to the token
#   POST /get           -> dataset request (body: key=value&key=value)
#   GET  /signin        -> enrollment instructions
#   POST /signin        -> accept a device public key (invite auto-accepts)
#   GET  /signin/<id>   -> device status
#   GET  /door          -> default server public key and WireGuard endpoint
#
# Static routes (everything else): the URL path mirrors a root directory.
#   /<hidden>/...       -> $SVR_ROOT/...   (hidden personal tree)
#   /a/b/c              -> $PUBLISHED_ROOT/a/b/c            (file)
#   /a/b                -> $PUBLISHED_ROOT/a/b/DEFAU*.sh    (directory -> default)
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
  local requested_path="$1" root_directory="${2:-${PUBLISHED_ROOT:-}}"
  local root_dir real_root target
  root_dir="$root_directory"
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
  local public_key device_name pass_message name existing trust status
  local invite_row invite_id device_id address response

  public_key="$(http_get_form_param public_key || true)"
  device_name="$(http_get_form_param device_name || true)"
  pass_message="$(http_get_form_param pass_message || true)"

  if [[ -z "$public_key" ]]; then
    http_send_response 400 "missing public_key"; return
  fi
  if ! device_validate_public_key "$public_key"; then
    http_send_response 400 "invalid public_key"; return
  fi
  name="$(device_name_sanitize "$device_name")"

  existing="$(device_find_by_public_key "$public_key" || true)"
  if [[ -n "$existing" ]]; then
    device_id="$(printf '%s' "$existing" | cut -f1)"
    status="$(printf '%s' "$existing" | cut -f6)"
    trust="$(printf '%s' "$existing" | cut -f5)"
    address="$(printf '%s' "$existing" | cut -f4)"
    http_send_response 200 "$(printf 'device_id=%s\nstatus=%s\ntrust=%s\naddress=%s' \
      "$device_id" "$status" "$trust" "$address")"
    return
  fi

  trust="guest"
  status="pending"
  if [[ -n "$pass_message" ]]; then
    invite_row="$(invite_find_usable_by_secret_hash "$(invite_hash_secret "$pass_message")" || true)"
    if [[ -n "$invite_row" ]]; then
      invite_id="$(printf '%s' "$invite_row" | cut -f1)"
      trust="$(printf '%s' "$invite_row" | cut -f2)"
      status="approved"
    fi
  fi

  device_id="$(device_add "$name" "$public_key" "$trust" "$status")" || {
    http_send_response 400 "cannot enroll device"
    return
  }
  if [[ -n "${invite_id:-}" ]]; then
    invite_consume "$invite_id" || true
  fi
  address="$(device_field "$device_id" 4)"
  http_send_response 200 "$(printf 'device_id=%s\nstatus=%s\ntrust=%s\naddress=%s' \
    "$device_id" "$status" "$trust" "$address")"
}

serve_device_status() {
  local device_id="$1" row
  row="$(device_find "$device_id")" || {
    http_send_response 404 "${NOT_FOUND_BODY:-404}"; return
  }
  [[ -n "$row" ]] || { http_send_response 404 "${NOT_FOUND_BODY:-404}"; return; }
  http_send_response 200 "$(printf 'device_id=%s\nstatus=%s\ntrust=%s\naddress=%s' \
    "$device_id" "$(printf '%s' "$row" | cut -f6)" \
    "$(printf '%s' "$row" | cut -f5)" "$(printf '%s' "$row" | cut -f4)")"
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
    "$(printf '%s' "$row" | cut -f3)" "$SERVER_HOST" "$WG_PORT" "$WG_NETWORK" \
    "$(printf '%s' "$row" | cut -f4)")"
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
      token_created_at="$(token_field "$token" 5)"
      if [[ "$token_status" == "pending" || "$token_status" == "" ]]; then
        now_seconds="$(date +%s)"
        if (( now_seconds - token_created_at > TOKEN_TTL_SECONDS )); then
          state_update "$STATE_DIR/db.tsv" 4 "expired" 2 "$token"
          http_send_response 410 "token expired or already used ($token_status)"
        else
          http_send_response 200 "$task_command"
        fi
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
    if personal_tree_relative_path="$(personal_tree_match_path "$url_path" 2>/dev/null)"; then
      serve_tree "$personal_tree_relative_path" "$(personal_tree_root)"
    else
      serve_tree "$url_path"
    fi
    ;;
esac
