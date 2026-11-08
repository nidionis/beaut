#!/usr/bin/env bash
# signin_test.sh — /signin enrollment, invite auto-accept, status and /door.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
. "$TESTS_DIR/lib/assert.sh"
. "$TESTS_DIR/lib/server.sh"

sandbox="$(mktemp -d)"
trap 'server_stop; rm -rf -- "$sandbox"' EXIT

published_root="$sandbox/shared"
state_directory="$sandbox/state"
mkdir -p "$published_root" "$state_directory"

export STATE_DIR="$state_directory"
export PUBLISHED_ROOT="$published_root"
export SERVER_HOST='127.0.0.1'
export WG_PORT=51820
export WG_NETWORK='10.66.0.0/24'
export WG_SERVER_IP='10.66.0.1'
export LOG_LEVEL='error'

. "$PROJECT_ROOT/scripts/lib/core.sh"
. "$PROJECT_ROOT/scripts/lib/devices.sh"
. "$PROJECT_ROOT/scripts/lib/invites.sh"
. "$PROJECT_ROOT/scripts/lib/http.sh"

device_registry_initialize
invite_registry_initialize
valid_device_key() {
  printf '%s%s=' "$(printf 'A%.0s' {1..42})" "$1"
}
server_key="$(valid_device_key 9)"
server_id="$(device_ensure_server "$server_key" "pserver")"

server_start "$published_root" "$state_directory"

response_field() {
  local response="$1" key="$2"
  printf '%s\n' "$response" | awk -F= -v k="$key" '$1==k{sub(/^[^=]*=/,""); print; exit}'
}

# --- form decoding ----------------------------------------------------------
request_body='public_key=abc%2Bdef%3D&empty=&plus=a+b'
assert_equal 'abc+def=' "$(http_get_form_param public_key)" "URL-decoded value keeps + and ="
assert_equal '' "$(http_get_form_param empty)" "empty value"
assert_equal 'a b' "$(http_get_form_param plus)" "plus means space"
request_body=''

# --- instructions and validation -------------------------------------------
http_get /signin
assert_status 200 "$HTTP_STATUS" "GET /signin should explain enrollment"
assert_contains "$HTTP_BODY" 'POST public_key' "instructions body"

http_post_fields /signin 'device_name=missing-key'
assert_status 400 "$HTTP_STATUS" "missing public key should be rejected"

http_post_fields /signin 'public_key=not-a-wireguard-key' 'device_name=bad'
assert_status 400 "$HTTP_STATUS" "invalid public key should be rejected"

# --- pending enrollment -----------------------------------------------------
pending_key="$(valid_device_key 1)"
http_post_fields /signin "public_key=$pending_key" 'device_name=living room' 'pass_message='
assert_status 200 "$HTTP_STATUS" "valid device should enroll"
pending_id="$(response_field "$HTTP_BODY" device_id)"
assert_matches '^[a-z0-9]{12}$' "$pending_id" "device id shape"
assert_equal 'pending' "$(response_field "$HTTP_BODY" status)" "no invite means pending"
assert_equal 'guest' "$(response_field "$HTTP_BODY" trust)" "pending trust is guest"
assert_equal '10.66.0.2' "$(response_field "$HTTP_BODY" address)" "pending device gets an address"
assert_equal 'living room' "$(device_field "$pending_id" 2)" "URL-decoded device name"

row_count_before="$(wc -l < "$(device_registry_file)")"
http_post_fields /signin "public_key=$pending_key" 'device_name=living room' 'pass_message='
assert_equal "$pending_id" "$(response_field "$HTTP_BODY" device_id)" "repeat signin is idempotent"
assert_equal "$row_count_before" "$(wc -l < "$(device_registry_file)")" "repeat signin adds no row"

http_get "/signin/$pending_id"
assert_status 200 "$HTTP_STATUS" "status route"
assert_equal 'pending' "$(response_field "$HTTP_BODY" status)" "status body"

http_get /signin/does-not-exist
assert_status 404 "$HTTP_STATUS" "unknown device status"

# --- door -------------------------------------------------------------------
http_get /door
assert_status 200 "$HTTP_STATUS" "door route"
assert_equal "$server_key" "$(response_field "$HTTP_BODY" public_key)" "door public key"
assert_equal '127.0.0.1:51820' "$(response_field "$HTTP_BODY" endpoint)" "door endpoint"
assert_equal '10.66.0.0/24' "$(response_field "$HTTP_BODY" network)" "door network"
assert_equal '10.66.0.1' "$(response_field "$HTTP_BODY" server_address)" "door server address"

# --- invite auto-accepts ----------------------------------------------------
invitation="$(invite_create trusted 1 0 'automatic')"
invite_id="${invitation%%$'\t'*}"
pass_message="${invitation#*$'\t'}"
invited_key="$(valid_device_key 2)"
http_post_fields /signin "public_key=$invited_key" 'device_name=phone' "pass_message=$pass_message"
assert_status 200 "$HTTP_STATUS" "invited device should enroll"
invited_id="$(response_field "$HTTP_BODY" device_id)"
assert_equal 'approved' "$(response_field "$HTTP_BODY" status)" "valid invite auto-accepts"
assert_equal 'trusted' "$(response_field "$HTTP_BODY" trust)" "invite trust is used"
assert_equal 'exhausted' "$(invite_field "$invite_id" 7)" "invite consumed"

# A used passMessage no longer auto-accepts a different key.
late_key="$(valid_device_key 3)"
http_post_fields /signin "public_key=$late_key" 'device_name=late' "pass_message=$pass_message"
assert_equal 'pending' "$(response_field "$HTTP_BODY" status)" "exhausted invite leaves the device pending"

# --- public keys with URL-sensitive characters ------------------------------
special_key="$(printf 'A%.0s' {1..41})+/="
http_post_fields /signin "public_key=$special_key" 'device_name=special'
assert_status 200 "$HTTP_STATUS" "base64 public key with + and / should survive form encoding"
special_id="$(response_field "$HTTP_BODY" device_id)"
assert_equal "$special_key" "$(device_field "$special_id" 3)" "public key stored exactly"
