#!/usr/bin/env bash
# net.sh — WireGuard + pare-feu (source unique, corrèle a tout le reseau).
# Usage : net.sh {open|nat|all|setup}
set -uo pipefail

NDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BDIR="$(cd "$NDIR/.." && pwd)"
. "$BDIR/lib/core.sh"

open_ports() {
  if cmd_exists nft; then
    nft add table inet beaut 2>/dev/null || true
    nft add chain inet beaut filter '{ type filter hook input priority 0 ; policy accept ; }' 2>/dev/null || true
    nft add rule inet beaut filter tcp dport "$HTTP_PORT" accept 2>/dev/null || true
    nft add rule inet beaut filter udp dport "$WG_PORT" accept 2>/dev/null || true
    nft add rule inet beaut filter iifname "wg0" accept 2>/dev/null || true
  elif cmd_exists iptables; then
    iptables -I INPUT -p tcp --dport "$HTTP_PORT" -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p udp --dport "$WG_PORT" -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -i wg0 -j ACCEPT 2>/dev/null || true
  fi
}

setup_nat() {
  if cmd_exists nft; then
    nft add table inet beaut 2>/dev/null || true
    nft add chain inet beaut nat '{ type nat hook postrouting priority 100 ; }' 2>/dev/null || true
    nft add rule inet beaut nat oifname != "wg0" masquerade 2>/dev/null || true
  elif cmd_exists iptables; then
    iptables -t nat -A POSTROUTING -o ! wg0 -j MASQUERADE 2>/dev/null || true
  fi
}

setup_wg() {
  cmd_exists wg || { log error "wireguard-tools requis (wg)"; exit 2; }
  cmd_exists ip || { log error "iproute2 requis (ip)"; exit 2; }

  WG_PRIV_KEY_FILE="$STATE_DIR/wg_private.key"
  WG_PUB_KEY_FILE="$STATE_DIR/wg_public.key"

  log info "generation des cles WireGuard"
  wg genkey | tee "$WG_PRIV_KEY_FILE" | wg pubkey > "$WG_PUB_KEY_FILE"
  chmod 600 "$WG_PRIV_KEY_FILE"

  log info "creation interface wg0 ($WG_SERVER_IP/24, port $WG_PORT)"
  ip link del wg0 2>/dev/null || true
  ip link add wg0 type wireguard
  ip address add "$WG_SERVER_IP/24" dev wg0
  wg set wg0 listen-port "$WG_PORT" private-key "$WG_PRIV_KEY_FILE"
  ip link set wg0 up

  setup_nat
  log info "WireGuard pret. Cle publique : $(cat "$WG_PUB_KEY_FILE")"
}

join_wg() {
  local server_pub="${1:?usage: join_wg <serveur_pub_key>}"
  cmd_exists wg || { log error "wireguard-tools requis (wg)"; exit 2; }
  cmd_exists ip || { log error "iproute2 requis (ip)"; exit 2; }

  WG_PRIV_KEY_FILE="$STATE_DIR/wg_private.key"
  WG_PUB_KEY_FILE="$STATE_DIR/wg_public.key"

  log info "generation des cles WireGuard node"
  wg genkey | tee "$WG_PRIV_KEY_FILE" | wg pubkey > "$WG_PUB_KEY_FILE"
  chmod 600 "$WG_PRIV_KEY_FILE"

  local_priv="$(cat "$WG_PRIV_KEY_FILE")"
  local_pub="$(cat "$WG_PUB_KEY_FILE")"

  # IP suivante dans le WG_NET (.2, .3, ...)
  local base="${WG_NET%/*}"
  local prefix="${base%.*}."
  local i=2
  while ip address show wg0 2>/dev/null | grep -q "$prefix$i"; do i=$((i+1)); done
  local wg_ip="${prefix}${i}"

  ip link del wg0 2>/dev/null || true
  ip link add wg0 type wireguard
  ip address add "$wg_ip/24" dev wg0
  wg set wg0 private-key "$WG_PRIV_KEY_FILE"
  wg set wg0 peer "$server_pub" endpoint "$DOMAIN:$WG_PORT" allowed-ips "$WG_NET" persistent-keepalive 25
  ip link set wg0 up

  log info "Node WireGuard pret. IP: $wg_ip  Cle publique: $local_pub"
}

case "${1:-all}" in
  open)   open_ports ;;
  nat)    setup_nat ;;
  all)    open_ports; setup_nat ;;
  setup)  setup_wg ;;
  join)   shift; join_wg "$@" ;;
  *)      echo "usage: $0 {open|nat|all|setup|join <cle_pub>}" >&2; exit 2 ;;
esac
