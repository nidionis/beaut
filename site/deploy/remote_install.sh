#!/usr/bin/env bash
# remote_install.sh — runs on the server as SERVICE_USER (after bootstrap).
# Applies the freshly uploaded tree: systemd user services + server processes.
set -euo pipefail

start_user_service() {
  local unit="$1" script="$2" log_file="$3" active_message="$4" fallback_message="$5"
  # `enable --now` does not restart an already-running unit. An upgrade must
  # restart so systemd re-reads ExecStart and the handler picks up the new tree
  # instead of keeping the previous release's environment and scripts.
  if command -v systemctl >/dev/null 2>&1 \
     && systemctl --user enable "$unit" >/dev/null 2>&1 \
     && systemctl --user restart "$unit" 2>/dev/null; then
    echo "$active_message"
    return 0
  fi
  pkill -f "$script" 2>/dev/null || true
  setsid bash "$HOME/.beaut/site/scripts/$script" \
    > "$HOME/.beaut/state/$log_file" 2>&1 < /dev/null &
  echo "$fallback_message"
}

mkdir -p ~/.config/systemd/user
cp -f ~/.beaut/site/deploy/beaut.service ~/.config/systemd/user/beaut.service
cp -f ~/.beaut/site/deploy/beaut-router.service ~/.config/systemd/user/beaut-router.service
command -v socat >/dev/null 2>&1 \
  || echo "warning: socat missing; the TCP router cannot forward service ports" >&2
systemctl --user daemon-reload 2>/dev/null || true

start_user_service beaut.service http_server.sh http.log \
  "beaut http service is active" \
  "http server started through setsid (see state/http.log)"
start_user_service beaut-router.service tcp_router.sh router.log \
  "beaut router service is active" \
  "tcp router started through setsid (see state/router.log)"
