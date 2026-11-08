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
. "$VIRTUAL_PATH_LIB_DIR/passphrase.sh"

attribution_directory() {
  printf '%s' "${ATTRIBUTION_DIRECTORY:-${STATE_DIR:?STATE_DIR is required}/attributions}"
}

attribution_registry_file() {
  printf '%s' "${ATTRIBUTION_REGISTRY:-$(attribution_directory)/registry.tsv}"
}

attribution_registry_initialize() {
  local directory registry
  directory="$(attribution_directory)"
  registry="$(attribution_registry_file)"
  mkdir -p -- "$directory"
  [[ -f "$registry" ]] || : > "$registry"
  chmod 700 "$directory" 2>/dev/null || true
  chmod 600 "$registry" 2>/dev/null || true
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

# Backwards-compatible aliases for callers of the original attribution helpers.
attribution_words_load() {
  passphrase_words_load "${ATTRIBUTION_DICTIONARY:-}"
  ATTRIBUTION_WORDS=("${PASSPHRASE_WORDS[@]}")
}

attribution_random_integer() {
  passphrase_random_integer "$@"
}

attribution_random_hex() {
  passphrase_random_hex "$@"
}

attribution_generate_secret() {
  passphrase_generate_secret "${1:-${ATTRIBUTION_SECRET_BYTES:-24}}"
}

attribution_generate_passphrase() {
  passphrase_generate_passphrase \
    "${1:-${ATTRIBUTION_WORD_COUNT:-4}}" "${ATTRIBUTION_DICTIONARY:-}"
}

attribution_generate_path() {
  local namespace="${1:-${ATTRIBUTION_PATH_NAMESPACE:-v}}"
  local word_count="${2:-${ATTRIBUTION_WORD_COUNT:-4}}"
  local passphrase suffix
  case "$namespace" in
    ''|*[!A-Za-z0-9._-]*) namespace="v" ;;
  esac
  passphrase="$(attribution_generate_passphrase "$word_count")" || return 1
  suffix="$(attribution_random_hex 3)"
  printf '/%s/%s-%s' "$namespace" "$passphrase" "$suffix"
}

attribution_find_row() {
  local virtual_path="${1:?missing virtual path}"
  local registry
  registry="$(attribution_registry_file)"
  [[ -f "$registry" ]] || return 1
  awk -F'\t' -v p="$virtual_path" '$3==p{print; exit}' "$registry"
}

attribution_find_row_by_identity() {
  local kind="${1:?missing kind}" name="${2:?missing name}"
  local registry
  registry="$(attribution_registry_file)"
  [[ -f "$registry" ]] || return 1
  awk -F'\t' -v k="$kind" -v n="$name" '$1==k && $2==n{print; exit}' "$registry"
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
  secret="$(attribution_generate_secret)"
  created_at="$(date +%s)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$kind" "$name" "$virtual_path" "$resource" "$secret" "$created_at" >> "$registry"
  printf '%s\t%s\n' "$virtual_path" "$secret"
}

# Reuse the attribution for kind/name (creating it when absent), refreshing the
# resource in place. Prints "virtual_path<TAB>secret".
attribution_ensure() {
  local kind="${1:?missing kind}" name="${2:?missing name}" resource="${3:?missing resource}"
  local word_count="${4:-${ATTRIBUTION_WORD_COUNT:-4}}" existing registry tmp
  attribution_validate_field kind "$kind" || return 1
  attribution_validate_field name "$name" || return 1
  attribution_validate_field resource "$resource" || return 1

  attribution_registry_initialize
  existing="$(attribution_find_row_by_identity "$kind" "$name")"
  if [[ -n "$existing" ]]; then
    registry="$(attribution_registry_file)"
    if [[ "$(printf '%s' "$existing" | cut -f4)" != "$resource" ]]; then
      tmp="$(mktemp)"
      awk -F'\t' -v OFS='\t' -v k="$kind" -v n="$name" -v r="$resource" \
        '$1==k && $2==n{$4=r} {print}' "$registry" > "$tmp"
      mv "$tmp" "$registry"
    fi
    printf '%s\t%s\n' "$(printf '%s' "$existing" | cut -f3)" "$(printf '%s' "$existing" | cut -f5)"
    return 0
  fi
  attribution_create "$kind" "$name" "$resource" "$word_count"
}

attribution_resolve() {
  local row
  row="$(attribution_find_row "${1:?missing virtual path}")" || return 1
  [[ -n "$row" ]] || return 1
  printf '%s' "$row" | cut -f4
}

# Replace the secret for a virtual path. Prints "virtual_path<TAB>secret".
attribution_rotate() {
  local virtual_path="${1:?missing virtual path}" secret registry tmp
  [[ -n "$(attribution_find_row "$virtual_path")" ]] || return 1
  secret="$(attribution_generate_secret)"
  registry="$(attribution_registry_file)"
  tmp="$(mktemp)"
  awk -F'\t' -v OFS='\t' -v p="$virtual_path" -v s="$secret" \
    '$3==p{$5=s} {print}' "$registry" > "$tmp"
  mv "$tmp" "$registry"
  printf '%s\t%s\n' "$virtual_path" "$secret"
}

attribution_remove() {
  local virtual_path="${1:?missing virtual path}" registry tmp
  [[ -n "$(attribution_find_row "$virtual_path")" ]] || return 1
  registry="$(attribution_registry_file)"
  tmp="$(mktemp)"
  awk -F'\t' -v p="$virtual_path" '$3!=p{print}' "$registry" > "$tmp"
  mv "$tmp" "$registry"
}

attribution_list() {
  local registry
  registry="$(attribution_registry_file)"
  [[ -f "$registry" ]] || return 0
  cat -- "$registry"
}
