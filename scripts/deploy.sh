#!/usr/bin/env bash
# scripts/deploy.sh — automated deploy of beaut to the ORCHESTRATOR via SSH+SFTP
#
#   sudo bash scripts/deploy.sh [ORCH_IP]
#
# Reads config.env for: BEAUT_PASSWORD, ROLE, IP_ORCHESTRATOR, IP_ROUTER, IP_DOMAIN, WORKERS, FRIENDS
#
# Flow:
#   1. build a tarball (install.sh + config.env + scripts + templates)
#   2. SFTP the tarball to the orchestrator ($IP_ORCHESTRATOR)
#   3. SSH into the orchestrator and run:
#        ./install.sh router     $IP_ORCHESTRATOR   # this node as router
#        ./install.sh orchestrator $IP_ROUTER       # this node as orchestrator
#   4. (optional, confirmed) slave the installing machine as a worker in $WORKERS
#   5. (optional, confirmed) slave the installing machine as a friend  in $FRIENDS
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
info() { printf '     %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# ── config ─────────────────────────────────────────────────────────────────
load_config() {
  local f="${1:-config.env}"
  [ -f "$f" ] || die "config.env not found — copy config.env.example to config.env and edit"
  # shellcheck disable=SC1090
  . "$f"
  : "${BEAUT_PASSWORD:?config.env must define BEAUT_PASSWORD}"
  : "${IP_ORCHESTRATOR:?config.env must define IP_ORCHESTRATOR}"
  : "${IP_ROUTER:?config.env must define IP_ROUTER}"
}

# ── helpers ────────────────────────────────────────────────────────────────
local_ip() {
  ip -4 addr show 2>/dev/null \
    | awk '/inet /{print $2}' | cut -d/ -f1 \
    | grep -v '^127\.' | head -1 || true
}

is_local() {
  [ "$1" = "127.0.0.1" ] || [ "$1" = "localhost" ]
}

ask() {
  read -rp "$1 [y/N] " ans
  case "$ans" in y|Y) return 0 ;; *) return 1 ;; esac
}

# append $ip to a KEY="..." line in config.env (create if missing)
add_to_config() {
  local key="$1" ip="$2"
  if grep -q "^${key}=" config.env; then
    sed -i "s|^${key}=.*|${key}=\"\${${key}} ${ip}\"|" config.env
  else
    printf '%s="%s"\n' "$key" "$ip" >> config.env
  fi
}

# ── steps ──────────────────────────────────────────────────────────────────
build_package() {
  log "building deploy package ..."
  local d; d="$(mktemp -d)"
  mkdir -p "$d/scripts" "$d/templates"
  cp install.sh config.env "$d/"
  cp -r scripts/. "$d/scripts/"
  cp -r templates/. "$d/templates/"
  tar czf "$d/beaut.tgz" -C "$d" install.sh config.env scripts templates
  echo "$d/beaut.tgz"
}

sftp_push() {
  local host="$1" tarball="$2"
  info "sftp push $tarball -> $host:~/beaut.tgz ..."
  echo "put $tarball ~/beaut.tgz" | sftp -q -o BatchMode=yes -o ConnectTimeout=10 "$host" >/dev/null 2>&1 \
    || die "sftp to $host failed"
}

ssh_cmd() {
  local host="$1" cmd="$2"
  info "ssh $host -> $cmd"
  ssh -t -o ConnectTimeout=10 "$host" "$cmd"
}

# install this node as router (toward orchestrator) then as orchestrator (toward router)
install_remote() {
  local host="$1"
  log "remote install on $host ..."
  ssh_cmd "$host" "tar xzf ~/beaut.tgz && cd ~ && sudo ./install.sh router     $IP_ORCHESTRATOR"
  ssh_cmd "$host" "cd ~                                && sudo ./install.sh orchestrator $IP_ROUTER"
}

# slave localhost as worker / friend (after confirmation)
slave_localhost() {
  local myip; myip="$(local_ip)"
  [ -n "$myip" ] || { warn "no non-127 local IP found — cannot slave localhost"; return 0; }

  echo
  if ask "Slave installing machine ($myip) as a worker in WORKERS?"; then
    add_to_config WORKERS "$myip"
    log "localhost $myip added to WORKERS"
  fi

  echo
  if ask "Slave installing machine ($myip) as a friend in FRIENDS?"; then
    add_to_config FRIENDS "$myip"
    log "localhost $myip added to FRIENDS"
  fi
}

# ── entry ──────────────────────────────────────────────────────────────────
main() {
  local target="${1:-$IP_ORCHESTRATOR}"
  [ -n "$target" ] || die "no target — pass an orchestrator IP or set IP_ORCHESTRATOR in config.env"
  [ "$(id -u)" = 0 ] || die "run as root: sudo bash scripts/deploy.sh [ORCH_IP]"

  load_config

  log "deploy to orchestrator: $target  (router=$IP_ROUTER)"

  local tarball; tarball="$(build_package)"
  sftp_push "$target" "$tarball"
  install_remote "$target"
  slave_localhost

  rm -f ~/beaut.tgz 2>/dev/null || true
  log "deploy complete on $target"
}

main "${1:-}"
