#!/usr/bin/env bash
# scripts/deploy.sh — push beaut to a remote node over SSH+SFTP (user-mode).
#
#   ./install.sh deploy [ORCH_IP]
#
# Flow: build tarball -> sftp it -> ssh install (router, then orchestrator)
#       -> optionally slave this machine as worker/friend.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$HERE/lib.sh"
cd "$ROOT"

ask() {
  local ans
  read -rp "$1 [y/N] " ans || true
  case "$ans" in y|Y) return 0 ;; *) return 1 ;; esac
}

build_package() {
  local d
  d="$(mktemp -d)"
  cp install.sh config.env Makefile "$d/"
  cp -r scripts templates src "$d/"
  tar czf "$d/beaut.tgz" -C "$d" install.sh config.env Makefile scripts templates src
  echo "$d/beaut.tgz"
}

sftp_push() {
  local host="$1" tarball="$2"
  info "sftp $tarball -> $host:~/beaut.tgz"
  echo "put $tarball ~/beaut.tgz" \
    | sftp -q -o BatchMode=yes -o ConnectTimeout=10 "$host" >/dev/null 2>&1 \
    || die "sftp to $host failed — check ssh access (no sudo needed)"
}

ssh_run() {
  local host="$1" cmd="$2"
  info "ssh $host: $cmd"
  ssh -t -o ConnectTimeout=10 "$host" "$cmd"
}

install_remote() {
  local host="$1"
  log "remote install on $host"
  ssh_run "$host" "tar xzf ~/beaut.tgz && cd ~ && ./install.sh --role router $IP_ORCHESTRATOR"
  ssh_run "$host" "cd ~ && ./install.sh --role orchestrator $IP_ROUTER"
}

slave_localhost() {
  local myip
  myip="$(local_ip)"
  [ -n "$myip" ] || { warn "no non-loopback IPv4 — cannot slave this machine"; return 0; }

  echo
  if ask "Add installing machine ($myip) to WORKERS?"; then
    conf_add config.env WORKERS "$myip"
    log "WORKERS += $myip"
  fi
  echo
  if ask "Add installing machine ($myip) to FRIENDS?"; then
    conf_add config.env FRIENDS "$myip"
    log "FRIENDS += $myip"
  fi
}

main() {
  load_config config.env
  : "${IP_ORCHESTRATOR:?config.env must define IP_ORCHESTRATOR}"
  local target="${1:-$IP_ORCHESTRATOR}"
  log "deploy -> $target (router=$IP_ROUTER)"

  local tarball
  tarball="$(build_package)"
  sftp_push "$target" "$tarball"
  install_remote "$target"
  slave_localhost
  log "deploy complete — $target:$BIN_DIR/$NAME (no sudo)"
}

main "${1:-}"
