#!/usr/bin/env bash
# lib/invites.sh — passMessage invites for device enrollment (sourced).
#
# The plaintext passMessage is shown once when an invite is created and is
# never stored: the registry only keeps its SHA-256 digest. An invite can be
# valid for a number of uses and/or a TTL. Only guest/trusted devices can be
# invited; owner is reserved for explicitly promoted servers.
#
# Registry columns:
#   invite_id | trust | secret_hash | max_uses | used_count | expires_at | status | created_at | note
set -uo pipefail

INVITES_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F has_command >/dev/null 2>&1; then
  . "$INVITES_LIB_DIR/core.sh"
fi
. "$INVITES_LIB_DIR/passphrase.sh"

invite_directory() {
  printf '%s' "${INVITE_DIRECTORY:-${STATE_DIR:?STATE_DIR is required}/invites}"
}

invite_registry_file() {
  printf '%s' "${INVITE_REGISTRY:-$(invite_directory)/registry.tsv}"
}

invite_registry_initialize() {
  local directory registry
  directory="$(invite_directory)"
  registry="$(invite_registry_file)"
  mkdir -p -- "$directory"
  [[ -f "$registry" ]] || : > "$registry"
  chmod 700 "$directory" 2>/dev/null || true
  chmod 600 "$registry" 2>/dev/null || true
}

invite_hash_secret() {
  local plaintext="${1:-}"
  [[ -n "$plaintext" ]] || {
    printf 'missing passMessage\n' >&2
    return 1
  }
  if has_command sha256sum; then
    printf '%s' "$plaintext" | sha256sum | awk '{print $1}'
  elif has_command shasum; then
    printf '%s' "$plaintext" | shasum -a 256 | awk '{print $1}'
  elif has_command openssl; then
    printf '%s' "$plaintext" | openssl dgst -sha256 | awk '{print $NF}'
  else
    printf 'no SHA-256 tool available (sha256sum, shasum or openssl)\n' >&2
    return 1
  fi
}

invite_validate_trust() {
  case "${1:-}" in
    guest|trusted) return 0 ;;
    *) return 1 ;;
  esac
}

invite_generate_id() {
  local candidate attempt registry
  registry="$(invite_registry_file)"
  for attempt in $(seq 1 200); do
    candidate="$(passphrase_random_alphanumeric 10)"
    if [[ -n "$candidate" && -z "$(invite_find "$candidate")" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

invite_find() {
  local invite_id="${1:-}" registry
  [[ -n "$invite_id" ]] || return 1
  registry="$(invite_registry_file)"
  [[ -f "$registry" ]] || return 1
  awk -F'\t' -v id="$invite_id" '$1==id{print; exit}' "$registry"
}

invite_field() {
  local invite_id="${1:?missing invite id}" column="${2:?missing column}"
  local row
  row="$(invite_find "$invite_id")" || return 1
  [[ -n "$row" ]] || return 1
  printf '%s' "$row" | cut -f "$column"
}

invite_update() {
  local invite_id="${1:?missing invite id}" column="${2:?missing column}" value="${3:-}"
  local registry temporary_file
  registry="$(invite_registry_file)"
  [[ -n "$(invite_find "$invite_id")" ]] || return 1
  temporary_file="$(mktemp)"
  awk -F'\t' -v OFS='\t' -v id="$invite_id" -v column="$column" -v value="$value" \
    '$1==id{$column=value} {print}' "$registry" > "$temporary_file"
  mv -- "$temporary_file" "$registry"
  chmod 600 "$registry" 2>/dev/null || true
}

invite_is_usable_row() {
  local row="${1:-}" now status expires_at max_uses used_count
  [[ -n "$row" ]] || return 1
  now="$(date +%s)"
  status="$(printf '%s' "$row" | cut -f7)"
  expires_at="$(printf '%s' "$row" | cut -f6)"
  max_uses="$(printf '%s' "$row" | cut -f4)"
  used_count="$(printf '%s' "$row" | cut -f5)"
  [[ "$status" == "active" ]] || return 1
  if [[ "$expires_at" =~ ^[0-9]+$ ]] && (( expires_at > 0 && now >= expires_at )); then
    return 1
  fi
  if [[ "$max_uses" =~ ^[0-9]+$ ]] && (( max_uses > 0 && used_count >= max_uses )); then
    return 1
  fi
  return 0
}

invite_find_usable_by_secret_hash() {
  local secret_hash="${1:-}" registry row
  [[ -n "$secret_hash" ]] || return 1
  registry="$(invite_registry_file)"
  [[ -f "$registry" ]] || return 1
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    [[ "$(printf '%s' "$row" | cut -f3)" == "$secret_hash" ]] || continue
    invite_is_usable_row "$row" || continue
    printf '%s\n' "$row"
    return 0
  done < "$registry"
  return 1
}

# Create an invite and print "invite_id<TAB>passMessage". The plaintext is
# generated here, returned to the operator once, and never written to disk.
invite_create() {
  local trust="${1:-guest}" max_uses="${2:-${INVITE_DEFAULT_USES:-1}}"
  local ttl_seconds="${3:-${INVITE_TTL_SECONDS:-86400}}" note="${4:-}"
  local invite_id secret_hash pass_message expires_at created_at registry
  invite_validate_trust "$trust" || {
    printf 'invalid invite trust: %s (guest or trusted only)\n' "$trust" >&2
    return 1
  }
  [[ "$max_uses" =~ ^[0-9]+$ ]] || {
    printf 'invalid invite max_uses: %s\n' "$max_uses" >&2
    return 1
  }
  [[ "$ttl_seconds" =~ ^[0-9]+$ ]] || {
    printf 'invalid invite ttl_seconds: %s\n' "$ttl_seconds" >&2
    return 1
  }
  case "$note" in
    *$'\t'*|*$'\n'*) printf 'invalid invite note\n' >&2; return 1 ;;
  esac

  invite_registry_initialize
  invite_id="$(invite_generate_id)" || return 1
  pass_message="$(passphrase_generate_passphrase "${INVITE_WORD_COUNT:-4}")-$(passphrase_random_hex 3)"
  secret_hash="$(invite_hash_secret "$pass_message")" || return 1
  created_at="$(date +%s)"
  if (( ttl_seconds > 0 )); then
    expires_at=$((created_at + ttl_seconds))
  else
    expires_at=0
  fi
  registry="$(invite_registry_file)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$invite_id" "$trust" "$secret_hash" "$max_uses" "0" "$expires_at" "active" "$created_at" "$note" \
    >> "$registry"
  chmod 600 "$registry" 2>/dev/null || true
  printf '%s\t%s' "$invite_id" "$pass_message"
}

invite_consume() {
  local invite_id="${1:?missing invite id}" used_count max_uses
  local row
  row="$(invite_find "$invite_id")" || return 1
  [[ -n "$row" ]] || return 1
  invite_is_usable_row "$row" || return 1
  used_count="$(printf '%s' "$row" | cut -f5)"
  max_uses="$(printf '%s' "$row" | cut -f4)"
  used_count=$((used_count + 1))
  invite_update "$invite_id" 5 "$used_count"
  if [[ "$max_uses" =~ ^[0-9]+$ ]] && (( max_uses > 0 && used_count >= max_uses )); then
    invite_update "$invite_id" 7 "exhausted"
  fi
}

invite_revoke() {
  local invite_id="${1:?missing invite id}"
  invite_update "$invite_id" 7 "revoked"
}

# Operators list invites without ever seeing the digest or plaintext.
invite_list() {
  local registry
  registry="$(invite_registry_file)"
  [[ -f "$registry" ]] || return 0
  printf 'invite_id\ttrust\tmax_uses\tused\texpires_at\tstatus\tcreated_at\tnote\n'
  awk -F'\t' -v OFS='\t' '{print $1,$2,$4,$5,$6,$7,$8,$9}' "$registry"
}
