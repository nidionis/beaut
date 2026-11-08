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

# Per-device keys live in state/wg. A pre-Batch-1 installation may still have
# state/wg_private.key / state/wg_public.key: keep using those instead of
# silently rotating the identity of an already joined server.
device_private_key_file() {
  local modern legacy
  if [[ -n "${WG_PRIVATE_KEY_FILE:-}" ]]; then
    printf '%s' "$WG_PRIVATE_KEY_FILE"
    return 0
  fi
  modern="$(device_key_directory)/device_private.key"
  legacy="${STATE_DIR:?STATE_DIR is required}/wg_private.key"
  if [[ -s "$modern" || ! -s "$legacy" ]]; then
    printf '%s' "$modern"
  else
    printf '%s' "$legacy"
  fi
}

device_public_key_file() {
  local modern legacy_private legacy_public private_file
  if [[ -n "${WG_PUBLIC_KEY_FILE:-}" ]]; then
    printf '%s' "$WG_PUBLIC_KEY_FILE"
    return 0
  fi
  modern="$(device_key_directory)/device_public.key"
  legacy_private="${STATE_DIR:?STATE_DIR is required}/wg_private.key"
  legacy_public="${STATE_DIR:?STATE_DIR is required}/wg_public.key"
  private_file="$(device_private_key_file)"
  if [[ "$private_file" == "$legacy_private" ]]; then
    printf '%s' "$legacy_public"
  else
    printf '%s' "$modern"
  fi
}

device_registry_initialize() {
  local directory registry
  directory="$(device_directory)"
  registry="$(device_registry_file)"
  mkdir -p -- "$directory"
  [[ -f "$registry" ]] || : > "$registry"
  chmod 700 "$directory" 2>/dev/null || true
  chmod 600 "$registry" 2>/dev/null || true
}

device_validate_public_key() {
  local public_key="$1"
  [[ "$public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

device_validate_name() {
  local name="$1"
  [[ -n "$name" ]] || return 1
  case "$name" in
    *$'\t'*|*$'\n'*|*/*) return 1 ;;
  esac
  (( ${#name} <= 64 ))
}

device_validate_trust() {
  case "${1:-}" in
    owner|trusted|guest) return 0 ;;
    *) return 1 ;;
  esac
}

device_validate_status() {
  case "${1:-}" in
    pending|approved|revoked) return 0 ;;
    *) return 1 ;;
  esac
}

device_find() {
  local device_id="${1:-}" registry
  [[ -n "$device_id" ]] || return 1
  registry="$(device_registry_file)"
  [[ -f "$registry" ]] || return 1
  awk -F'\t' -v id="$device_id" '$1==id{print; exit}' "$registry"
}

device_find_by_public_key() {
  local public_key="${1:-}" registry
  [[ -n "$public_key" ]] || return 1
  registry="$(device_registry_file)"
  [[ -f "$registry" ]] || return 1
  awk -F'\t' -v key="$public_key" '$3==key{print; exit}' "$registry"
}

device_field() {
  local device_id="${1:?missing device id}" column="${2:?missing column}"
  local row
  row="$(device_find "$device_id")" || return 1
  [[ -n "$row" ]] || return 1
  printf '%s' "$row" | cut -f "$column"
}

device_update() {
  local device_id="${1:?missing device id}" column="${2:?missing column}" value="${3:-}"
  local registry temporary_file
  registry="$(device_registry_file)"
  [[ -n "$(device_find "$device_id")" ]] || return 1
  temporary_file="$(mktemp)"
  awk -F'\t' -v OFS='\t' -v id="$device_id" -v column="$column" -v value="$value" \
    '$1==id{$column=value} {print}' "$registry" > "$temporary_file"
  mv -- "$temporary_file" "$registry"
  chmod 600 "$registry" 2>/dev/null || true
}

device_address_prefix() {
  local network_base
  network_base="${WG_NETWORK%/*}"
  printf '%s.' "${network_base%.*}"
}

device_address_in_use() {
  local address="${1:?missing address}" registry
  registry="$(device_registry_file)"
  [[ -f "$registry" ]] || return 1
  awk -F'\t' -v address="$address" '$4==address{found=1} END{exit(found?0:1)}' "$registry"
}

device_next_address() {
  local address_prefix index address
  address_prefix="$(device_address_prefix)"
  index=2
  while :; do
    address="$address_prefix$index"
    [[ "$address" == "${WG_SERVER_IP:-}" ]] && { index=$((index + 1)); continue; }
    device_address_in_use "$address" || break
    index=$((index + 1))
  done
  printf '%s' "$address"
}

device_generate_id() {
  local candidate attempt
  for attempt in $(seq 1 200); do
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
  local device_id="${5:-}" address="${6:-}" created_at registry
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
  if [[ -n "$(device_find_by_public_key "$public_key")" ]]; then
    printf 'a device with this public key already exists\n' >&2
    return 1
  fi
  [[ -n "$device_id" ]] || device_id="$(device_generate_id)" || return 1
  [[ -z "$(device_find "$device_id")" ]] || {
    printf 'device id already exists: %s\n' "$device_id" >&2
    return 1
  }
  if [[ -z "$address" ]]; then
    address="$(device_next_address)"
  elif device_address_in_use "$address"; then
    printf 'address already in use: %s\n' "$address" >&2
    return 1
  fi
  created_at="$(date +%s)"
  registry="$(device_registry_file)"
  if [[ "$status" == "approved" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$device_id" "$name" "$public_key" "$address" "$trust" "$status" "$created_at" "$created_at" \
      >> "$registry"
  else
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t\n' \
      "$device_id" "$name" "$public_key" "$address" "$trust" "$status" "$created_at" \
      >> "$registry"
  fi
  chmod 600 "$registry" 2>/dev/null || true
  printf '%s' "$device_id"
}

device_approve() {
  local device_id="${1:?missing device id}" trust="${2:-}"
  local row current_trust
  row="$(device_find "$device_id")" || return 1
  [[ -n "$row" ]] || return 1
  current_trust="$(printf '%s' "$row" | cut -f5)"
  [[ -n "$trust" ]] || trust="$current_trust"
  device_validate_trust "$trust" || {
    printf 'invalid trust level: %s\n' "$trust" >&2
    return 1
  }
  device_update "$device_id" 5 "$trust"
  device_update "$device_id" 6 "approved"
  device_update "$device_id" 8 "$(date +%s)"
}

device_revoke() {
  local device_id="${1:?missing device id}"
  [[ -n "$(device_find "$device_id")" ]] || return 1
  device_update "$device_id" 6 "revoked"
}

device_rename() {
  local device_id="${1:?missing device id}" name="${2:?missing device name}"
  device_validate_name "$name" || {
    printf 'invalid device name: %s\n' "$name" >&2
    return 1
  }
  device_update "$device_id" 2 "$name"
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
    if [[ -n "$(device_find "$override")" && "$(device_field "$override" 6)" == "approved" ]]; then
      printf '%s' "$override"
      return 0
    fi
    return 1
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
