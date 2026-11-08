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
load_config

usage() {
  sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

device_http_get() {
  local path="$1" response_file
  response_file="$(mktemp)"
  DEVICE_HTTP_STATUS="$(curl -s -o "$response_file" -w '%{http_code}' \
    "http://$SERVER_HOST:$HTTP_PORT$path")"
  DEVICE_HTTP_BODY="$(cat "$response_file")"
  rm -f -- "$response_file"
}

device_http_post_fields() {
  local path="$1"; shift
  local response_file field
  local -a curl_fields=()
  for field in "$@"; do
    curl_fields+=(--data-urlencode "$field")
  done
  response_file="$(mktemp)"
  DEVICE_HTTP_STATUS="$(curl -s -o "$response_file" -w '%{http_code}' \
    "${curl_fields[@]}" "http://$SERVER_HOST:$HTTP_PORT$path")"
  DEVICE_HTTP_BODY="$(cat "$response_file")"
  rm -f -- "$response_file"
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
  local pass_message="${1:-}" device_id name public_key
  device_id="$(device_local_identity_initialize "$(hostname 2>/dev/null || printf 'device')")" \
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

# Bring the live interface in line with the registry after a manual decision.
# Best effort: a client without wg0 or sudo simply skips it.
device_refresh_peers() {
  if [[ "$(id -u)" -eq 0 ]]; then
    bash "$SCRIPT_DIR/network.sh" sync-peers >/dev/null 2>&1 || true
  elif sudo -n true 2>/dev/null; then
    sudo -n bash "$SCRIPT_DIR/network.sh" sync-peers >/dev/null 2>&1 || true
  fi
}

device_register_request() {
  local public_key="${1:?missing public key}" name="${2:-device}" pass_message="${3:-}"
  local existing row trust="guest" status="pending" invite_row invite_id device_id
  device_validate_public_key "$public_key" || {
    printf 'invalid WireGuard public key\n' >&2
    return 1
  }
  existing="$(device_find_by_public_key "$public_key" || true)"
  if [[ -n "$existing" ]]; then
    printf 'device_id=%s\nstatus=%s\ntrust=%s\naddress=%s\n' \
      "$(printf '%s' "$existing" | cut -f1)" \
      "$(printf '%s' "$existing" | cut -f6)" \
      "$(printf '%s' "$existing" | cut -f5)" \
      "$(printf '%s' "$existing" | cut -f4)"
    return 0
  fi
  if [[ -n "$pass_message" ]]; then
    invite_row="$(invite_find_usable_by_secret_hash "$(invite_hash_secret "$pass_message")" || true)"
    if [[ -n "$invite_row" ]]; then
      invite_id="$(printf '%s' "$invite_row" | cut -f1)"
      trust="$(printf '%s' "$invite_row" | cut -f2)"
      status="approved"
    fi
  fi
  device_id="$(device_add "$name" "$public_key" "$trust" "$status")" || return 1
  if [[ -n "${invite_id:-}" ]]; then
    invite_consume "$invite_id" || true
  fi
  printf 'device_id=%s\nstatus=%s\ntrust=%s\naddress=%s\n' \
    "$device_id" "$status" "$trust" "$(device_field "$device_id" 4)"
}

device_invite_command() {
  local trust="guest" max_uses="${INVITE_DEFAULT_USES:-1}"
  local ttl_seconds="${INVITE_TTL_SECONDS:-86400}" note=""
  while (( $# > 0 )); do
    case "$1" in
      --trust)
        [[ $# -ge 2 ]] || { printf 'missing value for --trust\n' >&2; return 2; }
        trust="${2:-}"; shift 2
        ;;
      --uses)
        [[ $# -ge 2 ]] || { printf 'missing value for --uses\n' >&2; return 2; }
        max_uses="${2:-}"; shift 2
        ;;
      --ttl)
        [[ $# -ge 2 ]] || { printf 'missing value for --ttl\n' >&2; return 2; }
        ttl_seconds="${2:-}"; shift 2
        ;;
      --note)
        [[ $# -ge 2 ]] || { printf 'missing value for --note\n' >&2; return 2; }
        note="${2:-}"; shift 2
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
  device_local_identity_initialize "$(hostname 2>/dev/null || printf 'device')" >/dev/null \
    || return 1
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
    device_register_request "$@"
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
    if [[ "$(id -u)" -eq 0 ]]; then
      sync_wireguard_peers
    elif sudo -n true 2>/dev/null; then
      sudo -n bash "$SCRIPT_DIR/network.sh" sync-peers
    else
      printf 'sync-peers requires root (or passwordless sudo)\n' >&2
      exit 1
    fi
    ;;
  *)
    usage
    ;;
esac
