#!/usr/bin/env bash
# virtual_path_test.sh — virtual secrets/paths are random, unique, reusable,
# rotatable, and never materialized on disk.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
. "$TESTS_DIR/lib/assert.sh"

sandbox="$(mktemp -d)"
trap 'rm -rf -- "$sandbox"' EXIT

export STATE_DIR="$sandbox/state"
export PUBLISHED_ROOT="$sandbox/shared"
mkdir -p "$STATE_DIR" "$PUBLISHED_ROOT"

. "$PROJECT_ROOT/scripts/lib/virtual_path.sh"
attribution_registry_initialize

# --- create -----------------------------------------------------------------
created="$(attribution_create secret wg-server 'PUBLIC-KEY-VALUE')"
virtual_path="${created%%$'\t'*}"
secret="${created#*$'\t'}"

assert_matches '^/v/([a-z]+-)+[0-9a-f]{6}$' "$virtual_path" "virtual path shape"
assert_matches '^[0-9a-f]{48}$' "$secret" "secret shape (24 random bytes as hex)"
assert_equal 'PUBLIC-KEY-VALUE' "$(attribution_resolve "$virtual_path")" "resolve resource"
assert_file_missing "$PUBLISHED_ROOT$virtual_path" "virtual path must not exist on disk"

row="$(attribution_find_row "$virtual_path")"
assert_equal 'secret' "$(printf '%s' "$row" | cut -f1)" "row kind"
assert_equal 'wg-server' "$(printf '%s' "$row" | cut -f2)" "row name"
assert_equal "$secret" "$(printf '%s' "$row" | cut -f5)" "row secret"

# --- ensure: reuse identity, refresh resource -------------------------------
again="$(attribution_ensure secret wg-server 'PUBLIC-KEY-VALUE')"
assert_equal "$created" "$again" "ensure should reuse the same path and secret"

refreshed="$(attribution_ensure secret wg-server 'ROTATED-RESOURCE')"
assert_equal "$virtual_path" "${refreshed%%$'\t'*}" "ensure keeps the path"
assert_equal "$secret" "${refreshed#*$'\t'}" "ensure keeps the secret"
assert_equal 'ROTATED-RESOURCE' "$(attribution_resolve "$virtual_path")" "ensure refreshes resource"

# --- rotate: new secret, same path ------------------------------------------
rotated="$(attribution_rotate "$virtual_path")"
assert_equal "$virtual_path" "${rotated%%$'\t'*}" "rotation keeps the path"
assert_not_equal "$secret" "${rotated#*$'\t'}" "rotation changes the secret"
assert_equal "${rotated#*$'\t'}" "$(attribution_find_row "$virtual_path" | cut -f5)" "rotation persisted"

# --- uniqueness -------------------------------------------------------------
declare -A seen_paths=()
for index in $(seq 1 20); do
  entry="$(attribution_create service "service-$index" "resource-$index")"
  entry_path="${entry%%$'\t'*}"
  assert_equal "" "${seen_paths[$entry_path]:-}" "virtual path collision"
  seen_paths[$entry_path]=1
done

# --- custom dictionary ------------------------------------------------------
printf 'alpha\nbeta\ngamma\ndelta\n' > "$sandbox/dictionary.txt"
export ATTRIBUTION_DICTIONARY="$sandbox/dictionary.txt"
dictionary_entry="$(attribution_create request knock-1 'pending-approval' 4)"
assert_matches '^/v/(alpha|beta|gamma|delta)(-(alpha|beta|gamma|delta))*-[0-9a-f]{6}$' \
  "${dictionary_entry%%$'\t'*}" "custom dictionary words"

# Duplicate dictionary entries must not loop forever.
printf 'alpha\nalpha\nbeta\nbeta\n' > "$sandbox/duplicate-dictionary.txt"
export ATTRIBUTION_DICTIONARY="$sandbox/duplicate-dictionary.txt"
duplicate_entry="$(attribution_create request knock-duplicate 'pending-approval' 4)"
assert_matches '^/v/(alpha|beta)-(alpha|beta)-[0-9a-f]{6}$' \
  "${duplicate_entry%%$'\t'*}" "duplicate dictionary words are deduplicated"

# --- remove -----------------------------------------------------------------
attribution_remove "$virtual_path"
assert_failure "removed attribution should not resolve" attribution_resolve "$virtual_path"
assert_equal "" "$(attribution_find_row "$virtual_path")" "removed row is gone"
assert_failure "removing twice should fail" attribution_remove "$virtual_path"
