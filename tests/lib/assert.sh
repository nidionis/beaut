#!/usr/bin/env bash
# assert.sh — minimal assertion helpers for the beaut test suite.
# Every helper returns non-zero with a readable message on failure, so tests can
# run under `set -e`.

assert_equal() {
  local expected="$1" actual="$2" message="${3:-values differ}"
  if [[ "$expected" != "$actual" ]]; then
    printf 'assert_equal failed: %s\n  expected: [%s]\n  actual:   [%s]\n' \
      "$message" "$expected" "$actual" >&2
    return 1
  fi
}

assert_not_equal() {
  local unexpected="$1" actual="$2" message="${3:-values should differ}"
  if [[ "$unexpected" == "$actual" ]]; then
    printf 'assert_not_equal failed: %s\n  both values: [%s]\n' \
      "$message" "$actual" >&2
    return 1
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" message="${3:-substring missing}"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'assert_contains failed: %s\n  missing: [%s]\n  in:      [%s]\n' \
      "$message" "$needle" "$haystack" >&2
    return 1
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" message="${3:-unexpected substring found}"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'assert_not_contains failed: %s\n  found: [%s]\n' \
      "$message" "$needle" >&2
    return 1
  fi
}

assert_matches() {
  local pattern="$1" value="$2" message="${3:-value does not match}"
  if [[ ! "$value" =~ $pattern ]]; then
    printf 'assert_matches failed: %s\n  pattern: [%s]\n  value:   [%s]\n' \
      "$message" "$pattern" "$value" >&2
    return 1
  fi
}

assert_file_exists() {
  local path="$1" message="${2:-file should exist}"
  if [[ ! -e "$path" ]]; then
    printf 'assert_file_exists failed: %s\n  path: [%s]\n' "$message" "$path" >&2
    return 1
  fi
}

assert_file_missing() {
  local path="$1" message="${2:-file should not exist}"
  if [[ -e "$path" ]]; then
    printf 'assert_file_missing failed: %s\n  path: [%s]\n' "$message" "$path" >&2
    return 1
  fi
}

assert_status() {
  local expected="$1" actual="$2" message="${3:-unexpected HTTP status}"
  assert_equal "$expected" "$actual" "$message"
}

assert_success() {
  local message="${1:-command should succeed}"
  shift
  if ! "$@"; then
    printf 'assert_success failed: %s\n  command: %s\n' "$message" "$*" >&2
    return 1
  fi
}

assert_failure() {
  local message="${1:-command should fail}"
  shift
  if "$@"; then
    printf 'assert_failure failed: %s\n  command: %s\n' "$message" "$*" >&2
    return 1
  fi
}
