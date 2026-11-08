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
