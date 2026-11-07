#!/usr/bin/env bash
# network.sh — WireGuard + firewall (single source of truth for the network).
# Usage: network.sh {open|nat|all|setup|join <server_public_key>}
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/core.sh"
load_config

open_ports() {
  if has_command nft; then
    nft add table inet beaut 2>/dev/null || true
    nft add chain inet beaut filter '{ type filter hook input priority 0 ; policy accept ; }' 2>/dev/null || true
    nft add rule inet beaut filter tcp dport "$HTTP_PORT" accept 2>/dev/null || true
    nft add rule inet beaut filter udp dport "$WG_PORT" accept 2>/dev/null || true
    nft add rule inet beaut filter iifname "wg0" accept 2>/dev/null || true
  elif has_command iptables; then
    iptables -I INPUT -p tcp --dport "$HTTP_PORT" -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p udp --dport "$WG_PORT" -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -i wg0 -j ACCEPT 2>/dev/null || true
  fi
}

setup_nat() {
  if has_command nft; then
    nft add table inet beaut 2>/dev/null || true
    nft add chain inet beaut nat '{ type nat hook postrouting priority 100 ; }' 2>/dev/null || true
    nft add rule inet beaut nat oifname != "wg0" masquerade 2>/dev/null || true
  elif has_command iptables; then
    iptables -t nat -A POSTROUTING -o ! wg0 -j MASQUERADE 2>/dev/null || true
  fi
}

setup_wireguard() {
  has_command wg || die "wireguard-tools is required (wg)"
  has_command ip || die "iproute2 is required (ip)"

  WG_PRIVATE_KEY_FILE="$STATE_DIR/wg_private.key"
  WG_PUBLIC_KEY_FILE="$STATE_DIR/wg_public.key"

  log info "generating WireGuard keys"
  wg genkey | tee "$WG_PRIVATE_KEY_FILE" | wg pubkey > "$WG_PUBLIC_KEY_FILE"
  chmod 600 "$WG_PRIVATE_KEY_FILE"

  log info "creating interface wg0 ($WG_SERVER_IP/24, port $WG_PORT)"
  ip link del wg0 2>/dev/null || true
  ip link add wg0 type wireguard
  ip address add "$WG_SERVER_IP/24" dev wg0
  wg set wg0 listen-port "$WG_PORT" private-key "$WG_PRIVATE_KEY_FILE"
  ip link set wg0 up

  setup_nat
  log info "WireGuard ready. Public key: $(cat "$WG_PUBLIC_KEY_FILE")"
}

join_wireguard() {
  local server_public_key="${1:?usage: join_wireguard <server_public_key>}"
  has_command wg || die "wireguard-tools is required (wg)"
  has_command ip || die "iproute2 is required (ip)"

  WG_PRIVATE_KEY_FILE="$STATE_DIR/wg_private.key"
  WG_PUBLIC_KEY_FILE="$STATE_DIR/wg_public.key"

  log info "generating node WireGuard keys"
  wg genkey | tee "$WG_PRIVATE_KEY_FILE" | wg pubkey > "$WG_PUBLIC_KEY_FILE"
  chmod 600 "$WG_PRIVATE_KEY_FILE"

  local private_key public_key
  private_key="$(cat "$WG_PRIVATE_KEY_FILE")"
  public_key="$(cat "$WG_PUBLIC_KEY_FILE")"

  # Next IP in WG_NETWORK (.2, .3, ...)
  local base prefix index
  base="${WG_NETWORK%/*}"
  prefix="${base%.*}."
  index=2
  while ip address show wg0 2>/dev/null | grep -q "$prefix$index"; do index=$((index+1)); done
  local wireguard_ip="${prefix}${index}"

  ip link del wg0 2>/dev/null || true
  ip link add wg0 type wireguard
  ip address add "$wireguard_ip/24" dev wg0
  wg set wg0 private-key "$WG_PRIVATE_KEY_FILE"
  wg set wg0 peer "$server_public_key" endpoint "$SERVER_HOST:$WG_PORT" allowed-ips "$WG_NETWORK" persistent-keepalive 25
  ip link set wg0 up

  log info "node WireGuard ready. IP: $wireguard_ip  Public key: $public_key"
}

case "${1:-all}" in
  open)   open_ports ;;
  nat)    setup_nat ;;
  all)    open_ports; setup_nat ;;
  setup)  setup_wireguard ;;
  join)   shift; join_wireguard "$@" ;;
  *)      echo "usage: $0 {open|nat|all|setup|join <server_public_key>}" >&2; exit 2 ;;
esac
