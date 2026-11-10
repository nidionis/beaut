#!/usr/bin/env bash
# lib/devices.sh — per-device identities and the approved-device registry
# (sourced). One WireGuard key per device, generated once and persisted; the
# registry is the single source of truth for addresses, trust and approval.
#
# Registry columns:
#   device_id | name | public_key | address | trust | status | created_at | approved_at
#
# trust  : owner | trusted | guest
# status : pending | approved | revoked
set -uo pipefail

DEVICES_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F has_command >/dev/null 2>&1; then
  . "$DEVICES_LIB_DIR/core.sh"
fi
. "$DEVICES_LIB_DIR/passphrase.sh"
. "$DEVICES_LIB_DIR/invites.sh"

device_directory() {
  printf '%s' "${DEVICE_DIRECTORY:-${STATE_DIR:?STATE_DIR is required}/devices}"
}

device_registry_file() {
  printf '%s' "${DEVICE_REGISTRY:-$(device_directory)/registry.tsv}"
}

device_identity_directory() {
  printf '%s' "${DEVICE_IDENTITY_DIRECTORY:-${STATE_DIR:?STATE_DIR is required}/device}"
}

device_key_directory() {
  printf '%s' "${WG_KEY_DIRECTORY:-${STATE_DIR:?STATE_DIR is required}/wg}"
}

# Per-device key pair under state/wg. Keys are never rotated implicitly.
device_private_key_file() {
  printf '%s/device_private.key' "$(device_key_directory)"
}

device_public_key_file() {
  printf '%s/device_public.key' "$(device_key_directory)"
}

device_registry_initialize() {
  state_file_init "$(device_directory)" "$(device_registry_file)"
}

device_validate_public_key() {
  [[ "${1:-}" =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

device_validate_name() {
  local name="${1:-}"
  [[ -n "$name" ]] || return 1
  case "$name" in
    *$'\t'*|*$'\n'*|*/*) return 1 ;;
  esac
  (( ${#name} <= 64 ))
}

device_validate_trust() {
  case "${1:-}" in
    owner|trusted|guest) return 0 ;;
    *)                   return 1 ;;
  esac
}

device_validate_status() {
  case "${1:-}" in
    pending|approved|revoked) return 0 ;;
    *)                        return 1 ;;
  esac
}

device_find() {
  local device_id="${1:-}" registry
  [[ -n "$device_id" ]] || return 1
  registry="$(device_registry_file)"
  state_find "$registry" 1 "$device_id"
}

device_find_by_public_key() {
  local public_key="${1:-}" registry
  [[ -n "$public_key" ]] || return 1
  registry="$(device_registry_file)"
  state_find "$registry" 3 "$public_key"
}

device_field() {
  state_field "$(device_find "${1:?missing device id}")" "${2:?missing column}"
}

device_update() {
  local device_id="${1:?missing device id}" registry
  local column="${2:?missing column}" value="${3:-}"
  registry="$(device_registry_file)"
  [[ -n "$(device_find "$device_id")" ]] || return 1
  state_update "$registry" "$column" "$value" 1 "$device_id"
  chmod 600 "$registry" 2>/dev/null || true
}

device_address_prefix() {
  local base="${WG_NETWORK%/*}"
  printf '%s.' "${base%.*}"
}

device_address_in_use() {
  state_has "$(device_registry_file)" 4 "${1:?missing address}"
}

device_next_address() {
  local prefix index address
  prefix="$(device_address_prefix)"
  for (( index = 2; ; index++ )); do
    address="$prefix$index"
    [[ "$address" == "${WG_SERVER_IP:-}" ]] && continue
    device_address_in_use "$address" || break
  done
  printf '%s' "$address"
}

device_generate_id() {
  local candidate attempt
  for attempt in {1..200}; do
    candidate="$(passphrase_random_alphanumeric 12)"
    if [[ -n "$candidate" && -z "$(device_find "$candidate")" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# Add a device and print its id. Optional id/address make tests and server
# identity creation deterministic without weakening the normal random path.
device_add() {
  local name="${1:?missing device name}" public_key="${2:?missing public key}"
  local trust="${3:-guest}" status="${4:-pending}"
  local device_id="${5:-}" address="${6:-}" created_at approved_at="" registry
  device_validate_name "$name" || {
    printf 'invalid device name: %s\n' "$name" >&2
    return 1
  }
  device_validate_public_key "$public_key" || {
    printf 'invalid WireGuard public key\n' >&2
    return 1
  }
  device_validate_trust "$trust" || {
    printf 'invalid trust level: %s\n' "$trust" >&2
    return 1
  }
  device_validate_status "$status" || {
    printf 'invalid device status: %s\n' "$status" >&2
    return 1
  }
  device_registry_initialize
  [[ -z "$(device_find_by_public_key "$public_key")" ]] || {
    printf 'a device with this public key already exists\n' >&2
    return 1
  }
  [[ -n "$device_id" ]] || device_id="$(device_generate_id)" || return 1
  [[ -z "$(device_find "$device_id")" ]] || {
    printf 'device id already exists: %s\n' "$device_id" >&2
    return 1
  }
  if [[ -n "$address" ]]; then
    device_address_in_use "$address" && {
      printf 'address already in use: %s\n' "$address" >&2
      return 1
    }
  else
    address="$(device_next_address)"
  fi
  created_at="$(date +%s)"
  [[ "$status" == "approved" ]] && approved_at="$created_at"
  registry="$(device_registry_file)"
  state_append "$registry" \
    "$device_id" "$name" "$public_key" "$address" "$trust" "$status" "$created_at" "$approved_at"
  chmod 600 "$registry" 2>/dev/null || true
  printf '%s' "$device_id"
}

device_approve() {
  local device_id="${1:?missing device id}" trust="${2:-}" current_trust
  current_trust="$(device_field "$device_id" 5)" || return 1
  [[ -n "$trust" ]] || trust="$current_trust"
  device_validate_trust "$trust" || {
    printf 'invalid trust level: %s\n' "$trust" >&2
    return 1
  }
  device_update "$device_id" 5 "$trust" || return 1
  device_update "$device_id" 6 "approved" || return 1
  device_update "$device_id" 8 "$(date +%s)"
}

device_revoke() {
  local device_id="${1:?missing device id}"
  [[ -n "$(device_find "$device_id")" ]] || return 1
  device_update "$device_id" 6 "revoked"
}

device_list() {
  local registry
  registry="$(device_registry_file)"
  [[ -f "$registry" ]] || return 0
  cat -- "$registry"
}

device_approved_rows() {
  local registry
  registry="$(device_registry_file)"
  [[ -f "$registry" ]] || return 0
  awk -F'\t' '$6=="approved"' "$registry"
}

# The door is the oldest approved owner/trusted device unless DOOR_DEVICE_ID
# selects another one. This keeps the first trusted server as the default entry
# point while still allowing a deliberate override.
device_default_door_id() {
  local registry override owner_id
  override="${DOOR_DEVICE_ID:-}"
  if [[ -n "$override" ]]; then
    [[ "$(device_field "$override" 6 2>/dev/null)" == "approved" ]] || return 1
    printf '%s' "$override"
    return 0
  fi
  owner_id="$(device_owner_id || true)"
  if [[ -n "$owner_id" && "$(device_field "$owner_id" 6)" == "approved" ]]; then
    printf '%s' "$owner_id"
    return 0
  fi
  registry="$(device_registry_file)"
  [[ -f "$registry" ]] || return 1
  awk -F'\t' '$6=="approved" && $5=="trusted"{print $1; exit}' "$registry"
}

device_owner_id() {
  local registry
  registry="$(device_registry_file)"
  [[ -f "$registry" ]] || return 1
  awk -F'\t' '$5=="owner"{print $1; exit}' "$registry"
}

# Register the server itself once. The key is created by the caller through
# device_local_identity_initialize or ensure_wireguard_keys; deploy never
# rotates it.
device_ensure_server() {
  local public_key="${1:?missing server public key}" name="${2:-server}"
  local owner_id current_key
  owner_id="$(device_owner_id || true)"
  if [[ -n "$owner_id" ]]; then
    current_key="$(device_field "$owner_id" 3)"
    if [[ "$current_key" != "$public_key" ]]; then
      log warn "server public key changed; updating the owner registry row"
      device_update "$owner_id" 3 "$public_key"
    fi
    printf '%s' "$owner_id"
    return 0
  fi
  device_add "$name" "$public_key" "owner" "approved" "" "${WG_SERVER_IP:?WG_SERVER_IP is required}"
}

# Ensure this machine has a private/public key pair and a stable local id.
# The registry is intentionally untouched: a node is local until /signin.
device_local_identity_initialize() {
  local name="${1:-$(hostname 2>/dev/null || printf 'device')}"
  local private_file public_file identity_directory id_file name_file device_id
  private_file="$(device_private_key_file)"
  public_file="$(device_public_key_file)"
  identity_directory="$(device_identity_directory)"
  id_file="$identity_directory/id"
  name_file="$identity_directory/name"

  mkdir -p -- "$(dirname "$private_file")" "$identity_directory"
  chmod 700 "$identity_directory" 2>/dev/null || true

  if [[ ! -s "$private_file" ]]; then
    has_command wg || {
      printf 'wireguard-tools is required to generate a device key (wg)\n' >&2
      return 1
    }
    log info "generating device private key: $private_file"
    (umask 077; wg genkey > "$private_file")
  fi
  chmod 600 "$private_file"

  if [[ ! -s "$public_file" ]]; then
    has_command wg || {
      printf 'wireguard-tools is required to derive the device public key (wg)\n' >&2
      return 1
    }
    wg pubkey < "$private_file" > "$public_file"
  fi
  chmod 644 "$public_file"

  [[ -s "$id_file" ]] || passphrase_random_alphanumeric 12 > "$id_file"
  device_id="$(cat "$id_file")"
  if [[ ! -s "$name_file" ]]; then
    device_validate_name "$name" || name="device"
    printf '%s' "$name" > "$name_file"
  fi
  chmod 600 "$id_file" "$name_file" 2>/dev/null || true
  printf '%s' "$device_id"
}

device_local_id() {
  local id_file
  id_file="$(device_identity_directory)/id"
  [[ -s "$id_file" ]] || return 1
  cat -- "$id_file"
}

device_local_name() {
  local name_file
  name_file="$(device_identity_directory)/name"
  [[ -s "$name_file" ]] || return 1
  cat -- "$name_file"
}

device_local_public_key() {
  local public_file
  public_file="$(device_public_key_file)"
  [[ -s "$public_file" ]] || return 1
  cat -- "$public_file"
}

# Shared enrollment used by /signin and `device.sh request`: return the device
# on repeat, auto-approve through a usable invite, otherwise stay pending.
device_print_response() {
  local row="${1:-}"
  [[ -n "$row" ]] || return 1
  printf 'device_id=%s\nstatus=%s\ntrust=%s\naddress=%s\n' \
    "$(state_field "$row" 1)" "$(state_field "$row" 6)" \
    "$(state_field "$row" 5)" "$(state_field "$row" 4)"
}

device_enroll() {
  local name="${1:?missing device name}" public_key="${2:?missing public key}"
  local pass_message="${3:-}" existing invite_row invite_id trust="guest" status="pending"
  local device_id
  device_validate_public_key "$public_key" || {
    printf 'invalid WireGuard public key\n' >&2
    return 1
  }
  existing="$(device_find_by_public_key "$public_key" || true)"
  if [[ -n "$existing" ]]; then
    device_print_response "$existing"
    return 0
  fi
  if [[ -n "$pass_message" ]]; then
    invite_row="$(invite_find_usable_by_secret_hash "$(invite_hash_secret "$pass_message")" || true)"
    if [[ -n "$invite_row" ]]; then
      invite_id="$(state_field "$invite_row" 1)"
      trust="$(state_field "$invite_row" 2)"
      status="approved"
    fi
  fi
  device_id="$(device_add "$name" "$public_key" "$trust" "$status")" || return 1
  [[ -z "${invite_id:-}" ]] || invite_consume "$invite_id" || true
  device_print_response "$(device_find "$device_id")"
}
