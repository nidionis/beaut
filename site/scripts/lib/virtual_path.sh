#!/usr/bin/env bash
# lib/virtual_path.sh — flexible virtual secret/path attribution (sourced).
#
# A virtual path is random, human-readable, and never created on disk: the
# registry maps it to a resource (a secret, a key, a service, a request, a
# dataset, ...). Rotation replaces the secret without touching any file tree.
# This is a generic utility: it knows nothing about WireGuard.
#
# Registry columns: kind | name | virtual_path | resource | secret | created_at
set -uo pipefail

VIRTUAL_PATH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F state_find >/dev/null 2>&1; then
  . "$VIRTUAL_PATH_LIB_DIR/core.sh"
fi
. "$VIRTUAL_PATH_LIB_DIR/passphrase.sh"

attribution_directory() {
  printf '%s' "${ATTRIBUTION_DIRECTORY:-${STATE_DIR:?STATE_DIR is required}/attributions}"
}

attribution_registry_file() {
  printf '%s' "${ATTRIBUTION_REGISTRY:-$(attribution_directory)/registry.tsv}"
}

attribution_registry_initialize() {
  state_file_init "$(attribution_directory)" "$(attribution_registry_file)"
}

attribution_validate_field() {
  local label="$1" value="$2"
  case "$value" in
    *$'\t'*|*$'\n'*)
      printf 'invalid %s: tabs and newlines are not allowed\n' "$label" >&2
      return 1
      ;;
  esac
}

attribution_generate_path() {
  local namespace="${1:-${ATTRIBUTION_PATH_NAMESPACE:-v}}"
  local word_count="${2:-${ATTRIBUTION_WORD_COUNT:-4}}"
  local passphrase suffix
  case "$namespace" in
    ''|*[!A-Za-z0-9._-]*) namespace="v" ;;
  esac
  passphrase="$(passphrase_generate_passphrase "$word_count" "${ATTRIBUTION_DICTIONARY:-}")" || return 1
  suffix="$(passphrase_random_hex 3)"
  printf '/%s/%s-%s' "$namespace" "$passphrase" "$suffix"
}

attribution_find_row() {
  local registry
  registry="$(attribution_registry_file)"
  state_find "$registry" 3 "${1:?missing virtual path}"
}

attribution_find_row_by_identity() {
  local registry
  registry="$(attribution_registry_file)"
  state_find_two "$registry" 1 "${1:?missing kind}" 2 "${2:?missing name}"
}

# Create a fresh attribution. Prints "virtual_path<TAB>secret".
attribution_create() {
  local kind="${1:?missing kind}" name="${2:?missing name}" resource="${3:?missing resource}"
  local word_count="${4:-${ATTRIBUTION_WORD_COUNT:-4}}"
  local virtual_path secret created_at registry
  attribution_validate_field kind "$kind" || return 1
  attribution_validate_field name "$name" || return 1
  attribution_validate_field resource "$resource" || return 1

  attribution_registry_initialize
  if [[ -n "$(attribution_find_row_by_identity "$kind" "$name")" ]]; then
    printf 'attribution already exists for %s/%s\n' "$kind" "$name" >&2
    return 1
  fi

  registry="$(attribution_registry_file)"
  virtual_path="$(attribution_generate_path "" "$word_count")" || return 1
  while [[ -n "$(attribution_find_row "$virtual_path")" ]]; do
    virtual_path="$(attribution_generate_path "" "$word_count")" || return 1
  done
  secret="$(passphrase_generate_secret "${ATTRIBUTION_SECRET_BYTES:-24}")"
  created_at="$(date +%s)"
  state_append "$registry" "$kind" "$name" "$virtual_path" "$resource" "$secret" "$created_at"
  printf '%s\t%s\n' "$virtual_path" "$secret"
}

# Reuse the attribution for kind/name (creating it when absent), refreshing the
# resource in place. Prints "virtual_path<TAB>secret".
attribution_ensure() {
  local kind="${1:?missing kind}" name="${2:?missing name}" resource="${3:?missing resource}"
  local word_count="${4:-${ATTRIBUTION_WORD_COUNT:-4}}" existing registry virtual_path
  attribution_validate_field kind "$kind" || return 1
  attribution_validate_field name "$name" || return 1
  attribution_validate_field resource "$resource" || return 1

  attribution_registry_initialize
  existing="$(attribution_find_row_by_identity "$kind" "$name")"
  if [[ -n "$existing" ]]; then
    virtual_path="$(state_field "$existing" 3)"
    if [[ "$(state_field "$existing" 4)" != "$resource" ]]; then
      registry="$(attribution_registry_file)"
      state_update "$registry" 4 "$resource" 3 "$virtual_path"
    fi
    printf '%s\t%s\n' "$virtual_path" "$(state_field "$existing" 5)"
    return 0
  fi
  attribution_create "$kind" "$name" "$resource" "$word_count"
}

attribution_resolve() {
  local row
  row="$(attribution_find_row "${1:?missing virtual path}")" || return 1
  state_field "$row" 4
}

# Replace the secret for a virtual path. Prints "virtual_path<TAB>secret".
attribution_rotate() {
  local virtual_path="${1:?missing virtual path}" secret registry
  [[ -n "$(attribution_find_row "$virtual_path")" ]] || return 1
  secret="$(passphrase_generate_secret "${ATTRIBUTION_SECRET_BYTES:-24}")"
  registry="$(attribution_registry_file)"
  state_update "$registry" 5 "$secret" 3 "$virtual_path"
  printf '%s\t%s\n' "$virtual_path" "$secret"
}

attribution_remove() {
  local virtual_path="${1:?missing virtual path}" registry
  [[ -n "$(attribution_find_row "$virtual_path")" ]] || return 1
  registry="$(attribution_registry_file)"
  state_remove "$registry" 3 "$virtual_path"
}

attribution_list() {
  local registry
  registry="$(attribution_registry_file)"
  [[ -f "$registry" ]] || return 0
  cat -- "$registry"
}
