#!/usr/bin/env bash
# invite_test.sh — passMessage invites: hashed at rest, auto-accept usable for
# the configured number of uses, expiring and revocable.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
. "$TESTS_DIR/lib/assert.sh"

sandbox="$(mktemp -d)"
trap 'rm -rf -- "$sandbox"' EXIT

export STATE_DIR="$sandbox/state"
export LOG_LEVEL='error'
mkdir -p "$STATE_DIR"
. "$PROJECT_ROOT/scripts/lib/core.sh"
. "$PROJECT_ROOT/scripts/lib/invites.sh"

invite_registry_initialize

# --- create: plaintext returned once, digest stored ------------------------
created="$(invite_create trusted 2 0 'family')"
invite_id="${created%%$'\t'*}"
pass_message="${created#*$'\t'}"
registry="$(cat "$(invite_registry_file)")"

assert_matches '^[a-z0-9]{10}$' "$invite_id" "invite id shape"
assert_matches '^[a-z]+(-[a-z]+)+-[0-9a-f]{6}$' "$pass_message" "passMessage shape"
assert_contains "$registry" "$(invite_hash_secret "$pass_message")" "digest is stored"
assert_not_contains "$registry" "$pass_message" "plaintext passMessage is never stored"
assert_equal 'trusted' "$(printf '%s' "$(invite_find "$invite_id")" | cut -f2)" "invite trust"

# --- multiple uses ----------------------------------------------------------
row="$(invite_find_usable_by_secret_hash "$(invite_hash_secret "$pass_message")")"
assert_equal "$invite_id" "$(printf '%s' "$row" | cut -f1)" "usable invite found by digest"
invite_consume "$invite_id"
assert_equal '1' "$(invite_field "$invite_id" 5)" "first use counted"
assert_true_after_first="$(invite_find_usable_by_secret_hash "$(invite_hash_secret "$pass_message")")"
assert_contains "$assert_true_after_first" "$invite_id" "invite still usable after one use"
invite_consume "$invite_id"
assert_equal 'exhausted' "$(invite_field "$invite_id" 7)" "invite exhausted after max uses"
assert_failure "exhausted invite is not usable" \
  invite_find_usable_by_secret_hash "$(invite_hash_secret "$pass_message")"

# --- expiry -----------------------------------------------------------------
expiring="$(invite_create guest 1 0 'expires')"
expiring_id="${expiring%%$'\t'*}"
expiring_pass="${expiring#*$'\t'}"
invite_update "$expiring_id" 6 1
assert_failure "expired invite is not usable" \
  invite_find_usable_by_secret_hash "$(invite_hash_secret "$expiring_pass")"

# --- revocation -------------------------------------------------------------
revoked="$(invite_create guest 5 0 'revoked')"
revoked_id="${revoked%%$'\t'*}"
revoked_pass="${revoked#*$'\t'}"
invite_revoke "$revoked_id"
assert_equal 'revoked' "$(invite_field "$revoked_id" 7)" "revoked status"
assert_failure "revoked invite is not usable" \
  invite_find_usable_by_secret_hash "$(invite_hash_secret "$revoked_pass")"

# --- trust and input validation --------------------------------------------
assert_failure "owner cannot be invited" invite_create owner 1 0 ''
assert_failure "unknown trust cannot be invited" invite_create stranger 1 0 ''
assert_failure "invalid max uses" invite_create guest not-a-number 0 ''

# --- listing never leaks the digest ----------------------------------------
listing="$(invite_list)"
assert_contains "$listing" 'invite_id' "invite list header"
assert_contains "$listing" "$invite_id" "invite list row"
digest="$(invite_field "$invite_id" 3)"
assert_not_contains "$listing" "$digest" "invite list hides the digest"
