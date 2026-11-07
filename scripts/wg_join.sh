#!/usr/bin/env bash
# wg_join.sh — configure WireGuard côté AGENT.
# Rejoint le serveur WireGuard, génère ses clés, ajoute le peer serveur.
set -uo pipefail

HDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BDIR="$(cd "$HDIR/.." && pwd)"
. "$BDIR/lib/core.sh"

SERVER_PUB_KEY="${1:-}"
[[ -n "$SERVER_PUB_KEY" ]] || { log error "usage: wg_join.sh <serveur_pub_key>"; exit 2; }

cmd_exists wg || { log error "wireguard-tools requis (wg)"; exit 2; }
cmd_exists ip || { log error "iproute2 requis (ip)"; exit 2; }

# Trouver une IP libre dans le WG_NET (simple : .2, .3, …)
next_wg_ip() {
  local base="${WG_NET%/*}"   # 10.66.0.0
  local prefix="${base%.*}."  # 10.66.0.
  local i=2
  while ip address show wg0 2>/dev/null | grep -q "$prefix$i"; do
    i=$((i+1))
  done
  echo "${prefix}${i}"
}

WG_IP="$(next_wg_ip)"
log info "adresse WireGuard assignée : $WG_IP"

WG_PRIV_KEY_FILE="$STATE_DIR/wg_private.key"
WG_PUB_KEY_FILE="$STATE_DIR/wg_public.key"

log info "génération des clés WireGuard agent"
wg genkey | tee "$WG_PRIV_KEY_FILE" | wg pubkey > "$WG_PUB_KEY_FILE"
chmod 600 "$WG_PRIV_KEY_FILE"

local_priv="$(cat "$WG_PRIV_KEY_FILE")"
local_pub="$(cat "$WG_PUB_KEY_FILE")"

ip link del wg0 2>/dev/null || true
ip link add wg0 type wireguard
ip address add "$WG_IP/24" dev wg0
wg set wg0 private-key "$WG_PRIV_KEY_FILE"
wg set wg0 peer "$SERVER_PUB_KEY" endpoint "$DOMAIN:$WG_PORT" allowed-ips "$WG_NET" persistent-keepalive 25
ip link set wg0 up

# Enregistre l'IP et la clé publique du worker auprès du serveur (via /give)
tsv_append "$STATE_DIR/workers.tsv" "$(hostname)" "$local_pub" "guest" "$WG_IP" "$(date +%s)" "alive"

log info "WireGuard agent prêt. IP: $WG_IP  Clé publique: $local_pub"
log info "L'agent est maintenant joignable sur $WG_IP via le VPN"
