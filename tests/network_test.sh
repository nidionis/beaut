#!/usr/bin/env bash
# network_test.sh — WireGuard key reuse and idempotent firewall rules without
# root: `wg`, `ip`, `nft` and `iptables` are local fakes.
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
  genkey) printf 'PRIVATE-KEY-FIXED\n' ;;
  pubkey) cat >/dev/null; printf 'PUBLIC-KEY-DERIVED\n' ;;
  show)
    if [[ "${2:-}" == "wg0" && "${3:-}" == "peers" ]]; then
      [[ -f "${FAKE_WG_PEERS:-/nonexistent}" ]] && cat "$FAKE_WG_PEERS" || true
    fi
    ;;
  set)
    if [[ -n "${FAKE_WG_STATE:-}" ]]; then
      printf 'wg %s\n' "$*" >> "$FAKE_WG_STATE"
    fi
    if [[ "${2:-}" == "wg0" && "${3:-}" == "peer" && -n "${FAKE_WG_PEERS:-}" ]]; then
      peer_key="${4:-}"
      if [[ "${5:-}" == "remove" ]]; then
        grep -vxF -- "$peer_key" "$FAKE_WG_PEERS" > "$FAKE_WG_PEERS.tmp" 2>/dev/null || true
        mv -- "$FAKE_WG_PEERS.tmp" "$FAKE_WG_PEERS"
      elif [[ -n "$peer_key" ]]; then
        grep -qxF -- "$peer_key" "$FAKE_WG_PEERS" 2>/dev/null || printf '%s\n' "$peer_key" >> "$FAKE_WG_PEERS"
      fi
    fi
    ;;
  *) exit 2 ;;
esac
FAKE_WG

cat > "$fake_bin/ip" <<'FAKE_IP'
#!/usr/bin/env bash
if [[ "${*:1:5}" == "-4 address show dev wg0" ]]; then
  printf '    inet 10.66.0.2/24 scope global wg0\n'
  printf '    inet 10.66.0.3/24 scope global secondary wg0\n'
fi
FAKE_IP

cat > "$fake_bin/nft" <<'FAKE_NFT'
#!/usr/bin/env bash
state="${FAKE_NFT_STATE:?}"
case "${1:-}" in
  list)
    [[ "${2:-}" == "chain" ]] && cat "$state.${5:-}" 2>/dev/null || true
    ;;
  add)
    if [[ "${2:-}" == "rule" ]]; then
      printf '%s\n' "${*:6}" >> "$state.${5:-}"
    fi
    ;;
  delete)
    if [[ "${2:-}" == "chain" ]]; then
      rm -f -- "$state.${5:-}"
    fi
    ;;
esac
FAKE_NFT

chmod 755 "$fake_bin/wg" "$fake_bin/ip" "$fake_bin/nft"
export PATH="$fake_bin:$PATH"
export FAKE_NFT_STATE="$sandbox/nft-state"
export STATE_DIR="$sandbox/state"
export WG_NETWORK='10.66.0.0/24'
export WG_SERVER_IP='10.66.0.1'
export WG_PORT=51820
export HTTP_PORT=8080
export LOG_LEVEL=error

. "$PROJECT_ROOT/scripts/lib/core.sh"
. "$PROJECT_ROOT/scripts/lib/wireguard.sh"

# --- pure address helpers ---------------------------------------------------
assert_equal '24' "$(wireguard_network_prefix)" "network prefix"
assert_equal '10.66.0.0' "$(wireguard_network_base)" "network base"
assert_equal '10.66.0.' "$(wireguard_address_prefix)" "address prefix"
assert_equal '10.66.0.4' "$(next_wireguard_node_address)" "next free node address"

# --- stateful ip fake for interface idempotence -----------------------------
cat > "$fake_bin/ip" <<'FAKE_IP_STATEFUL'
#!/usr/bin/env bash
state="${FAKE_IP_STATE:?}"
printf '%s\n' "$*" >> "$state.commands"
case "$*" in
  "-4 address show dev wg0")
    [[ -f "$state.interface" ]] || exit 1
    if [[ -f "$state.addresses" ]]; then
      while IFS= read -r address; do
        [[ -n "$address" ]] && printf '    inet %s scope global wg0\n' "$address"
      done < "$state.addresses"
    fi
    ;;
  "link show wg0")
    [[ -f "$state.interface" ]]
    ;;
  "link add wg0 type wireguard")
    : > "$state.interface"
    ;;
  "link del wg0")
    rm -f "$state.interface" "$state.addresses"
    ;;
  "link set wg0 up")
    : ;;
  "address add "*)
    printf '%s\n' "$3" >> "$state.addresses"
    ;;
esac
FAKE_IP_STATEFUL
chmod 755 "$fake_bin/ip"
export FAKE_IP_STATE="$sandbox/ip-state"
export FAKE_WG_STATE="$sandbox/wg-state"
export FAKE_WG_PEERS="$sandbox/wg-peers"
: > "$FAKE_WG_PEERS"
export SERVER_HOST='127.0.0.1'

# --- key reuse --------------------------------------------------------------
ensure_wireguard_keys
first_private="$(cat "$(wireguard_private_key_file)")"
first_public="$(cat "$(wireguard_public_key_file)")"
assert_equal 'PRIVATE-KEY-FIXED' "$first_private" "generated private key"
assert_equal 'PUBLIC-KEY-DERIVED' "$first_public" "derived public key"

ensure_wireguard_keys
assert_equal "$first_private" "$(cat "$(wireguard_private_key_file)")" "private key is reused"
assert_equal "$first_public" "$(cat "$(wireguard_public_key_file)")" "public key is reused"

rm -f "$(wireguard_public_key_file)"
ensure_wireguard_keys
assert_equal "$first_public" "$(cat "$(wireguard_public_key_file)")" "missing public key is rebuilt"

# --- firewall rules are rebuilt, never duplicated ---------------------------
open_ports
open_ports
assert_equal '3' "$(wc -l < "$FAKE_NFT_STATE.filter")" "open_ports should converge to 3 rules"
assert_contains "$(cat "$FAKE_NFT_STATE.filter")" 'tcp dport 8080 accept' "http rule"
assert_contains "$(cat "$FAKE_NFT_STATE.filter")" 'udp dport 51820 accept' "wireguard rule"
assert_contains "$(cat "$FAKE_NFT_STATE.filter")" 'iifname wg0 accept' "interface rule"

setup_nat
setup_nat
assert_equal '1' "$(wc -l < "$FAKE_NFT_STATE.nat")" "nat chain should converge to 1 rule"
assert_contains "$(cat "$FAKE_NFT_STATE.nat")" 'oifname != wg0 masquerade' "nat masquerade"

# --- server interface is reused --------------------------------------------
rm -f "$FAKE_IP_STATE".* "$FAKE_WG_STATE"
configure_wireguard_server
server_add_count="$(grep -c '^link add wg0 type wireguard$' "$FAKE_IP_STATE.commands" || true)"
server_delete_count="$(grep -c '^link del wg0$' "$FAKE_IP_STATE.commands" || true)"
assert_equal '1' "$server_add_count" "server interface created once"
assert_contains "$(cat "$FAKE_IP_STATE.addresses")" '10.66.0.1/24' "server address"

configure_wireguard_server
assert_equal "$server_add_count" \
  "$(grep -c '^link add wg0 type wireguard$' "$FAKE_IP_STATE.commands" || true)" \
  "server interface is reused"
assert_equal "$server_delete_count" \
  "$(grep -c '^link del wg0$' "$FAKE_IP_STATE.commands" || true)" \
  "server reuse must not delete wg0"

# --- node interface is reused ----------------------------------------------
rm -f "$FAKE_IP_STATE".* "$FAKE_WG_STATE"
join_wireguard 'SERVER-PUBLIC-KEY'
join_wireguard 'SERVER-PUBLIC-KEY'
assert_equal '1' \
  "$(grep -c '^link add wg0 type wireguard$' "$FAKE_IP_STATE.commands" || true)" \
  "node interface created once"
assert_equal '1' \
  "$(grep -c '^address add ' "$FAKE_IP_STATE.commands" || true)" \
  "node address added once"
assert_contains "$(cat "$FAKE_IP_STATE.addresses")" '10.66.0.2/24' "node address"
assert_contains "$(cat "$FAKE_WG_STATE")" 'peer SERVER-PUBLIC-KEY' "peer configured"

# --- per-device peers from the registry ------------------------------------
device_registry_initialize
test_key() {
  printf '%s%s=' "$(printf 'A%.0s' {1..42})" "$1"
}
approved_key="$(test_key 1)"
pending_key="$(test_key 2)"
revoked_key="$(test_key 3)"
approved_id="$(device_add laptop "$approved_key" trusted approved)"
pending_id="$(device_add phone "$pending_key" guest pending)"
revoked_id="$(device_add tablet "$revoked_key" guest approved)"
device_revoke "$revoked_id"

sync_wireguard_peers
assert_contains "$(cat "$FAKE_WG_PEERS")" "$approved_key" "approved device becomes a peer"
assert_not_contains "$(cat "$FAKE_WG_PEERS")" "$pending_key" "pending device is not a peer"
assert_not_contains "$(cat "$FAKE_WG_PEERS")" "$revoked_key" "revoked device is not a peer"
assert_contains "$(cat "$FAKE_WG_STATE")" "allowed-ips 10.66.0.2/32" "approved address is scoped to /32"
# Unknown peers (not in the registry) are left alone.
assert_contains "$(cat "$FAKE_WG_PEERS")" 'SERVER-PUBLIC-KEY' "unknown peer is preserved"

# Idempotence: a second sync must not remove an already-converged peer.
sync_wireguard_peers
assert_contains "$(cat "$FAKE_WG_PEERS")" "$approved_key" "approved peer survives a second sync"
assert_not_contains "$(cat "$FAKE_WG_PEERS")" "$pending_key" "pending peer stays absent"

device_revoke "$approved_id"
sync_wireguard_peers
assert_not_contains "$(cat "$FAKE_WG_PEERS")" "$approved_key" "revoked peer is removed"

# --- client configuration uses the registry address -----------------------
configure_wireguard_client 'SERVER-PUBLIC-KEY' '10.66.0.9'
assert_contains "$(cat "$FAKE_IP_STATE.addresses")" '10.66.0.9/24' "client address"
assert_contains "$(cat "$FAKE_WG_STATE")" 'peer SERVER-PUBLIC-KEY' "client server peer"
assert_contains "$(cat "$FAKE_WG_STATE")" 'endpoint 127.0.0.1:51820' "client endpoint"
