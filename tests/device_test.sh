#!/usr/bin/env bash
# device_test.sh — per-device identity, address allocation, approval/revocation
# and the default door. No root, no real WireGuard.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
. "$TESTS_DIR/lib/assert.sh"

sandbox="$(mktemp -d)"
trap 'rm -rf -- "$sandbox"' EXIT

fake_bin="$sandbox/bin"
mkdir -p "$fake_bin" "$sandbox/state"
cat > "$fake_bin/wg" <<'FAKE_WG'
#!/usr/bin/env bash
case "${1:-}" in
  genkey)
    printf 'genkey\n' >> "${FAKE_WG_LOG:?}"
    printf 'PRIVATE-DEVICE-KEY\n'
    ;;
  pubkey)
    cat >/dev/null
    printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n'
    ;;
  *) exit 2 ;;
esac
FAKE_WG
chmod 755 "$fake_bin/wg"
export PATH="$fake_bin:$PATH"
export FAKE_WG_LOG="$sandbox/wg.log"

export STATE_DIR="$sandbox/state"
export WG_NETWORK='10.66.0.0/24'
export WG_SERVER_IP='10.66.0.1'
export LOG_LEVEL='error'

. "$PROJECT_ROOT/scripts/lib/core.sh"
. "$PROJECT_ROOT/scripts/lib/devices.sh"

device_registry_initialize
device_key() {
  printf '%s%s=' "$(printf 'A%.0s' {1..42})" "$1"
}
first_key="$(device_key 1)"
second_key="$(device_key 2)"
third_key="$(device_key 3)"
server_key="$(device_key 9)"

# --- add / address allocation ----------------------------------------------
first_id="$(device_add laptop "$first_key" guest pending)"
assert_matches '^[a-z0-9]{12}$' "$first_id" "device id shape"
assert_equal '10.66.0.2' "$(device_field "$first_id" 4)" "first allocated address"
assert_equal 'pending' "$(device_field "$first_id" 6)" "new device is pending"
assert_equal "$first_id" "$(printf '%s' "$(device_find_by_public_key "$first_key")" | cut -f1)" "lookup by public key"

second_id="$(device_add phone "$second_key" guest pending)"
assert_equal '10.66.0.3' "$(device_field "$second_id" 4)" "second allocated address"
assert_not_equal "$first_id" "$second_id" "device ids are distinct"

# --- duplicate / invalid input ---------------------------------------------
assert_failure "duplicate public key must fail" device_add other "$first_key" guest pending
assert_failure "invalid public key must fail" device_add other 'not-a-key' guest pending
assert_failure "invalid trust must fail" device_add other "$third_key" stranger pending
assert_failure "invalid status must fail" device_add other "$third_key" guest waiting
assert_failure "names with tabs must fail" device_add $'bad\tname' "$third_key" guest pending

# --- approval / revocation --------------------------------------------------
device_approve "$first_id" trusted
assert_equal 'approved' "$(device_field "$first_id" 6)" "approved status"
assert_equal 'trusted' "$(device_field "$first_id" 5)" "approved trust"
assert_matches '^[0-9]+$' "$(device_field "$first_id" 8)" "approved_at timestamp"

device_revoke "$second_id"
assert_equal 'revoked' "$(device_field "$second_id" 6)" "revoked status"

# Addresses stay reserved after revocation: a new device never collides with a
# peer that may still be configured in WireGuard.
third_id="$(device_add tablet "$third_key" guest pending)"
assert_equal '10.66.0.4' "$(device_field "$third_id" 4)" "revoked address stays reserved"

# --- server identity / door -------------------------------------------------
server_id="$(device_ensure_server "$server_key" "pserver")"
assert_equal "$server_id" "$(device_owner_id)" "owner is the server"
assert_equal '10.66.0.1' "$(device_field "$server_id" 4)" "server address"
assert_equal "$server_id" "$(device_default_door_id)" "default door is the oldest trusted server"
assert_equal "$server_id" "$(device_ensure_server "$server_key" "pserver")" "server identity is idempotent"

export DOOR_DEVICE_ID="$first_id"
assert_equal "$first_id" "$(device_default_door_id)" "door override"
unset DOOR_DEVICE_ID

# --- local identity ---------------------------------------------------------
local_id_first="$(device_local_identity_initialize 'laptop')"
local_id_second="$(device_local_identity_initialize 'laptop')"
assert_equal "$local_id_first" "$local_id_second" "local id is stable"
assert_matches '^[a-z0-9]{12}$' "$local_id_first" "local id shape"
assert_equal 'laptop' "$(device_local_name)" "local name"
assert_equal 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' "$(device_local_public_key)" "local public key"
assert_equal '1' "$(wc -l < "$FAKE_WG_LOG")" "private key is generated exactly once"
assert_file_exists "$(device_private_key_file)" "private key file exists"

# --- CLI: request, invite auto-accept, list --------------------------------
cli_pending="$(cd "$PROJECT_ROOT" && bash scripts/device.sh request "$(device_key 5)" 'cli-laptop')"
assert_contains "$cli_pending" 'status=pending' "CLI request is pending without an invite"

invite_output="$(cd "$PROJECT_ROOT" && bash scripts/device.sh invite --trust trusted --uses 1 --ttl 0 --note cli)"
pass_message="$(printf '%s\n' "$invite_output" | awk -F= '$1=="pass_message"{sub(/^[^=]*=/,""); print; exit}')"
assert_matches '^[a-z]+(-[a-z]+)+-[0-9a-f]{6}$' "$pass_message" "CLI invite prints a passMessage"

cli_approved="$(cd "$PROJECT_ROOT" && bash scripts/device.sh request "$(device_key 6)" 'cli-phone' "$pass_message")"
assert_contains "$cli_approved" 'status=approved' "CLI invite auto-accepts"
assert_contains "$cli_approved" 'trust=trusted' "CLI invite trust"

cli_list="$(cd "$PROJECT_ROOT" && bash scripts/device.sh list)"
assert_contains "$cli_list" 'cli-phone' "CLI list includes the device"
assert_contains "$cli_list" 'cli-laptop' "CLI list includes pending devices"

cli_invites="$(cd "$PROJECT_ROOT" && bash scripts/device.sh invites)"
assert_contains "$cli_invites" 'invite_id' "CLI invite list header"
assert_contains "$cli_invites" 'cli' "CLI invite list note"
assert_failure "invite option without a value is rejected" \
  bash -c "cd '$PROJECT_ROOT' && bash scripts/device.sh invite --trust"
