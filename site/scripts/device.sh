#!/usr/bin/env bash
# device.sh — per-device identity, enrollment and approval CLI.
#
# Server side:
#   device.sh init [name]                 create/reuse the server identity + owner row
#   device.sh invite [options]            create a passMessage invite (plaintext shown once)
#   device.sh invites                     list invites (digest never shown)
#   device.sh request <public_key> [name] [pass_message]
#   device.sh approve <device_id> [trust] approve a pending device
#   device.sh revoke <device_id>          revoke access
#   device.sh list                        registry
#   device.sh show <device_id>
#   device.sh door                        print the default door
#   device.sh sync-peers                  apply approved devices to wg0
#
# Device side:
#   device.sh signin [pass_message]       submit this device public key
#   device.sh status [device_id]          ask the server for a device status
#   device.sh join [pass_message]         sign in and configure WireGuard
#
# Invite options: --trust guest|trusted, --uses N, --ttl SECONDS, --note TEXT.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/core.sh"
. "$SCRIPT_DIR/lib/devices.sh"
. "$SCRIPT_DIR/lib/invites.sh"
. "$SCRIPT_DIR/lib/http.sh"
load_config

usage() {
  sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

device_http_get() {
  http_request GET "$1"
  DEVICE_HTTP_STATUS="$http_status"
  DEVICE_HTTP_BODY="$http_body"
}

device_http_post_fields() {
  local path="$1"; shift
  local field
  local -a curl_fields=()
  for field in "$@"; do
    curl_fields+=(--data-urlencode "$field")
  done
  http_request POST "$path" \
    -H 'Content-Type: application/x-www-form-urlencoded' "${curl_fields[@]}"
  DEVICE_HTTP_STATUS="$http_status"
  DEVICE_HTTP_BODY="$http_body"
}

device_response_field() {
  local response="${1:-}" key="${2:-}" line
  while IFS= read -r line; do
    if [[ "$line" == "$key="* ]]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  done <<< "$response"
  return 1
}

# Fail loudly instead of printing an error page as if it were a result.
device_require_http_ok() {
  local action="${1:-request}"
  if [[ "${DEVICE_HTTP_STATUS:-}" != "200" ]]; then
    printf '%s failed (HTTP %s)\n%s\n' \
      "$action" "${DEVICE_HTTP_STATUS:-000}" "${DEVICE_HTTP_BODY:-}" >&2
    return 1
  fi
}

device_signin() {
  local pass_message="${1:-}" name public_key
  device_local_identity_initialize "$(hostname 2>/dev/null || printf 'device')" >/dev/null \
    || return 1
  name="$(device_local_name 2>/dev/null || printf 'device')"
  public_key="$(device_local_public_key)" || return 1
  device_http_post_fields /signin \
    "public_key=$public_key" \
    "device_name=$name" \
    "pass_message=$pass_message" || return 1
  device_require_http_ok signin || return 1
  printf '%s' "$DEVICE_HTTP_BODY"
}

device_run_network() {
  if [[ "$(id -u)" -eq 0 ]]; then
    bash "$SCRIPT_DIR/network.sh" "$@"
  elif sudo -n true 2>/dev/null; then
    sudo -n bash "$SCRIPT_DIR/network.sh" "$@"
  else
    return 1
  fi
}

# Bring the live interface in line with the registry after a manual decision.
# Best effort: a client without wg0 or sudo simply skips it.
device_refresh_peers() {
  device_run_network sync-peers >/dev/null 2>&1 || true
}

device_invite_command() {
  local trust="guest" max_uses="${INVITE_DEFAULT_USES:-1}"
  local ttl_seconds="${INVITE_TTL_SECONDS:-86400}" note=""
  while (( $# > 0 )); do
    case "$1" in
      --trust|--uses|--ttl|--note)
        [[ $# -ge 2 ]] || { printf 'missing value for %s\n' "$1" >&2; return 2; }
        case "$1" in
          --trust) trust="$2" ;;
          --uses)  max_uses="$2" ;;
          --ttl)   ttl_seconds="$2" ;;
          --note)  note="$2" ;;
        esac
        shift 2
        ;;
      *) printf 'unknown invite option: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  local created invite_id pass_message
  created="$(invite_create "$trust" "$max_uses" "$ttl_seconds" "$note")" || return 1
  invite_id="${created%%$'\t'*}"
  pass_message="${created#*$'\t'}"
  printf 'invite_id=%s\ntrust=%s\nuses=%s\nttl_seconds=%s\npass_message=%s\n' \
    "$invite_id" "$trust" "$max_uses" "$ttl_seconds" "$pass_message"
}

device_join() {
  local pass_message="${1:-}" response status device_id address door_response
  local server_public_key network endpoint
  response="$(device_signin "$pass_message")" || return 1
  status="$(device_response_field "$response" status || true)"
  device_id="$(device_response_field "$response" device_id || true)"
  address="$(device_response_field "$response" address || true)"
  printf '%s\n' "$response"
  if [[ "$status" != "approved" ]]; then
    printf 'device is %s; ask the server owner to approve %s\n' "${status:-unknown}" "${device_id:-this device}" >&2
    return 3
  fi
  [[ -n "$address" ]] || {
    printf 'server did not return a device address\n' >&2
    return 1
  }
  device_http_get /door || return 1
  device_require_http_ok door || return 1
  door_response="$DEVICE_HTTP_BODY"
  server_public_key="$(device_response_field "$door_response" public_key || true)"
  network="$(device_response_field "$door_response" network || true)"
  endpoint="$(device_response_field "$door_response" endpoint || true)"
  [[ -n "$server_public_key" ]] || {
    printf 'server door has no public key\n' >&2
    return 1
  }

  local network_command=("$SCRIPT_DIR/network.sh" client "$server_public_key" "$address")
  if [[ "$(id -u)" -eq 0 ]]; then
    WG_NETWORK="${network:-$WG_NETWORK}" WG_SERVER_ENDPOINT="${endpoint:-$SERVER_HOST:$WG_PORT}" \
      bash "${network_command[@]}"
  elif sudo -n true 2>/dev/null; then
    sudo -n env "WG_NETWORK=${network:-$WG_NETWORK}" \
      "WG_SERVER_ENDPOINT=${endpoint:-$SERVER_HOST:$WG_PORT}" \
      bash "${network_command[@]}"
  else
    printf 'device is approved; run as root with:\n  WG_NETWORK=%s WG_SERVER_ENDPOINT=%s %s\n' \
      "${network:-$WG_NETWORK}" "${endpoint:-$SERVER_HOST:$WG_PORT}" "${network_command[*]}" >&2
    return 1
  fi
}

command="${1:-}"
[[ -n "$command" ]] || usage
shift

case "$command" in
  init)
    name="${1:-$(hostname 2>/dev/null || printf 'server')}"
    device_local_identity_initialize "$name" >/dev/null || exit 1
    device_id="$(device_ensure_server "$(device_local_public_key)" "$name")" || exit 1
    printf 'device_id=%s\nname=%s\naddress=%s\npublic_key=%s\n' \
      "$device_id" "$name" "$(device_field "$device_id" 4)" "$(device_local_public_key)"
    ;;
  invite)
    device_invite_command "$@"
    ;;
  invites)
    invite_list
    ;;
  request)
    device_enroll "${2:-device}" "${1:?missing public key}" "${3:-}"
    ;;
  approve)
    device_id="${1:?missing device id}"
    device_approve "$device_id" "${2:-}" || exit 1
    device_refresh_peers
    printf 'approved %s (trust %s); peers refreshed\n' \
      "$device_id" "$(device_field "$device_id" 5)"
    ;;
  revoke)
    device_id="${1:?missing device id}"
    device_revoke "$device_id" || exit 1
    device_refresh_peers
    printf 'revoked %s; peers refreshed\n' "$device_id"
    ;;
  list)
    printf 'device_id\tname\tpublic_key\taddress\ttrust\tstatus\tcreated_at\tapproved_at\n'
    device_list
    ;;
  show)
    row="$(device_find "${1:?missing device id}")" || exit 1
    [[ -n "$row" ]] || { printf 'unknown device: %s\n' "$1" >&2; exit 1; }
    printf '%s\n' "$row"
    ;;
  door)
    device_http_get /door || exit 1
    device_require_http_ok door || exit 1
    printf '%s\n' "$DEVICE_HTTP_BODY"
    ;;
  signin)
    response="$(device_signin "${1:-}")" || exit 1
    printf '%s\n' "$response"
    ;;
  status)
    device_id="${1:-$(device_local_id || true)}"
    [[ -n "$device_id" ]] || { printf 'missing device id\n' >&2; exit 1; }
    device_http_get "/signin/$device_id" || exit 1
    device_require_http_ok "status for $device_id" || exit 1
    printf '%s\n' "$DEVICE_HTTP_BODY"
    ;;
  join)
    device_join "${1:-}"
    ;;
  sync-peers)
    device_run_network sync-peers || {
      printf 'sync-peers requires root (or passwordless sudo)\n' >&2
      exit 1
    }
    ;;
  *)
    usage
    ;;
esac
