#!/usr/bin/env bash
# lib/wireguard.sh — idempotent WireGuard and firewall helpers (sourced).
# Every function is safe to re-run: keys are reused, an already configured
# interface is kept, and each firewall chain converges to one rule set.
set -uo pipefail

wireguard_private_key_file() {
  printf '%s' "${WG_PRIVATE_KEY_FILE:-$STATE_DIR/wg_private.key}"
}

wireguard_public_key_file() {
  printf '%s' "${WG_PUBLIC_KEY_FILE:-$STATE_DIR/wg_public.key}"
}

wireguard_network_prefix() {
  printf '%s' "${WG_NETWORK##*/}"
}

wireguard_network_base() {
  printf '%s' "${WG_NETWORK%/*}"
}

wireguard_address_prefix() {
  local base
  base="$(wireguard_network_base)"
  printf '%s.' "${base%.*}"
}

# Reuse existing keys; generate only what is missing. This keeps a server
# public key stable across deploys, so previously joined peers stay valid.
ensure_wireguard_keys() {
  local private_file public_file
  private_file="$(wireguard_private_key_file)"
  public_file="$(wireguard_public_key_file)"
  mkdir -p -- "$STATE_DIR"

  if [[ -s "$private_file" ]]; then
    log debug "reusing WireGuard private key: $private_file"
  else
    log info "generating WireGuard private key"
    (umask 077; wg genkey > "$private_file")
  fi
  chmod 600 "$private_file"

  if [[ -s "$public_file" ]]; then
    log debug "reusing WireGuard public key: $public_file"
  else
    wg pubkey < "$private_file" > "$public_file"
  fi
  chmod 644 "$public_file"
}

wireguard_interface_exists() {
  ip link show wg0 >/dev/null 2>&1
}

wireguard_interface_has_address() {
  local address="$1"
  ip -4 address show dev wg0 2>/dev/null | grep -Fq "inet $address/"
}

wireguard_interface_address() {
  ip -4 address show dev wg0 2>/dev/null \
    | awk '/inet /{sub(/\/.*/, "", $2); print $2; exit}'
}

next_wireguard_node_address() {
  local address_prefix index existing_addresses
  address_prefix="$(wireguard_address_prefix)"
  existing_addresses="$(ip -4 address show dev wg0 2>/dev/null || true)"
  index=2
  while printf '%s\n' "$existing_addresses" | grep -Fq "$address_prefix$index/"; do
    index=$((index + 1))
  done
  printf '%s%s' "$address_prefix" "$index"
}

nft_rebuild_filter_chain() {
  nft add table inet beaut 2>/dev/null || true
  # Rebuilding the chain converges to exactly one rule set on every run.
  nft delete chain inet beaut filter 2>/dev/null || true
  nft add chain inet beaut filter \
    '{ type filter hook input priority 0 ; policy accept ; }' 2>/dev/null || true
  nft add rule inet beaut filter tcp dport "$HTTP_PORT" accept 2>/dev/null || true
  nft add rule inet beaut filter udp dport "$WG_PORT" accept 2>/dev/null || true
  nft add rule inet beaut filter iifname wg0 accept 2>/dev/null || true
}

nft_rebuild_nat_chain() {
  nft add table inet beaut 2>/dev/null || true
  nft delete chain inet beaut nat 2>/dev/null || true
  nft add chain inet beaut nat \
    '{ type nat hook postrouting priority 100 ; }' 2>/dev/null || true
  nft add rule inet beaut nat oifname != wg0 masquerade 2>/dev/null || true
}

iptables_rule_is_present() {
  iptables -C "$@" >/dev/null 2>&1
}

iptables_ensure_rule() {
  iptables_rule_is_present "$@" && return 0
  iptables -I "$@" >/dev/null 2>&1 || true
}

iptables_nat_rule_is_present() {
  iptables -t nat -C "$@" >/dev/null 2>&1
}

iptables_nat_ensure_rule() {
  iptables_nat_rule_is_present "$@" && return 0
  iptables -t nat -I "$@" >/dev/null 2>&1 || true
}

open_ports() {
  if has_command nft; then
    nft_rebuild_filter_chain
  elif has_command iptables; then
    iptables_ensure_rule INPUT -p tcp --dport "$HTTP_PORT" -j ACCEPT
    iptables_ensure_rule INPUT -p udp --dport "$WG_PORT" -j ACCEPT
    iptables_ensure_rule INPUT -i wg0 -j ACCEPT
  fi
}

setup_nat() {
  if has_command nft; then
    nft_rebuild_nat_chain
  elif has_command iptables; then
    iptables_nat_ensure_rule POSTROUTING ! -o wg0 -j MASQUERADE
  fi
}

configure_wireguard_server() {
  has_command wg || die "wireguard-tools is required (wg)"
  has_command ip || die "iproute2 is required (ip)"

  ensure_wireguard_keys
  local private_file address_prefix
  private_file="$(wireguard_private_key_file)"
  address_prefix="$(wireguard_network_prefix)"

  if wireguard_interface_exists && wireguard_interface_has_address "$WG_SERVER_IP"; then
    log info "reusing interface wg0 ($WG_SERVER_IP/$address_prefix, port $WG_PORT)"
    wg set wg0 listen-port "$WG_PORT" private-key "$private_file" || true
    ip link set wg0 up || true
  else
    log info "creating interface wg0 ($WG_SERVER_IP/$address_prefix, port $WG_PORT)"
    ip link del wg0 2>/dev/null || true
    ip link add wg0 type wireguard
    ip address add "$WG_SERVER_IP/$address_prefix" dev wg0
    wg set wg0 listen-port "$WG_PORT" private-key "$private_file"
    ip link set wg0 up
  fi

  open_ports
  setup_nat
  log info "WireGuard ready. Public key: $(cat "$(wireguard_public_key_file)")"
}

join_wireguard() {
  local server_public_key="${1:?usage: join_wireguard <server_public_key>}"
  has_command wg || die "wireguard-tools is required (wg)"
  has_command ip || die "iproute2 is required (ip)"

  ensure_wireguard_keys
  local private_file public_file address_prefix node_address
  private_file="$(wireguard_private_key_file)"
  public_file="$(wireguard_public_key_file)"
  address_prefix="$(wireguard_network_prefix)"

  if wireguard_interface_exists; then
    node_address="$(wireguard_interface_address)"
  fi
  [[ -n "${node_address:-}" ]] || node_address="$(next_wireguard_node_address)"

  if wireguard_interface_exists; then
    log info "reusing interface wg0 ($node_address/$address_prefix)"
  else
    ip link add wg0 type wireguard
    log info "created interface wg0 ($node_address/$address_prefix)"
  fi

  if ! wireguard_interface_has_address "$node_address"; then
    ip address add "$node_address/$address_prefix" dev wg0
  fi
  wg set wg0 private-key "$private_file"
  wg set wg0 peer "$server_public_key" \
    endpoint "$SERVER_HOST:$WG_PORT" \
    allowed-ips "$WG_NETWORK" \
    persistent-keepalive 25
  ip link set wg0 up

  log info "node WireGuard ready. IP: $node_address  Public key: $(cat "$public_file")"
}
