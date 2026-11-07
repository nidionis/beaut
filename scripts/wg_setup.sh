#!/usr/bin/env bash
# wg_setup.sh — configure WireGuard côté SERVEUR.
# Génère les clés, crée l'interface wg0, active le masquerade.
set -uo pipefail

HDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BDIR="$(cd "$HDIR/.." && pwd)"
. "$BDIR/lib/core.sh"

WG_PRIV_KEY_FILE="$STATE_DIR/wg_private.key"
WG_PUB_KEY_FILE="$STATE_DIR/wg_public.key"

cmd_exists wg || { log error "wireguard-tools requis (wg)"; exit 2; }
cmd_exists ip || { log error "iproute2 requis (ip)"; exit 2; }

log info "génération des clés WireGuard serveur"
wg genkey | tee "$WG_PRIV_KEY_FILE" | wg pubkey > "$WG_PUB_KEY_FILE"
chmod 600 "$WG_PRIV_KEY_FILE"

local_priv="$(cat "$WG_PRIV_KEY_FILE")"

log info "création de l'interface wg0 ($WG_SERVER_IP/24, port $WG_PORT)"
ip link del wg0 2>/dev/null || true
ip link add wg0 type wireguard
ip address add "$WG_SERVER_IP/24" dev wg0
wg set wg0 listen-port "$WG_PORT" private-key "$WG_PRIV_KEY_FILE"
ip link set wg0 up

# Masquerade pour sortir vers le WAN via le VPN
if cmd_exists nft; then
  nft add table inet beaut 2>/dev/null || true
  nft add chain inet beaut nat '{ type nat hook postrouting priority 100 ; }' 2>/dev/null || true
  nft add rule inet beaut nat oifname != "wg0" masquerade 2>/dev/null || true
elif cmd_exists iptables; then
  iptables -t nat -A POSTROUTING -o ! wg0 -j MASQUERADE 2>/dev/null || true
fi

log info "WireGuard serveur prêt. Clé publique :"
cat "$WG_PUB_KEY_FILE"
log info "Partagez cette clé publique avec les agents via wg_join.sh"
