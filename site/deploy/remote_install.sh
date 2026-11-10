#!/usr/bin/env bash
# remote_install.sh — runs on the server as SERVICE_USER (after bootstrap).
# Applies the freshly uploaded tree: systemd user services + server processes.
set -euo pipefail

mkdir -p ~/.config/systemd/user
cp -f ~/.beaut/site/deploy/beaut.service ~/.config/systemd/user/beaut.service
cp -f ~/.beaut/site/deploy/beaut-router.service ~/.config/systemd/user/beaut-router.service
command -v socat >/dev/null 2>&1 \
  || echo "warning: socat missing; the TCP router cannot forward service ports" >&2
systemctl --user daemon-reload 2>/dev/null || true

# `enable --now` does not restart an already-running unit. An upgrade must
# restart so systemd re-reads ExecStart and the handler picks up the new tree
# instead of keeping the previous release's environment and scripts.
if command -v systemctl >/dev/null 2>&1 \
   && systemctl --user enable beaut.service >/dev/null 2>&1 \
   && systemctl --user restart beaut.service 2>/dev/null; then
  echo "beaut http service is active"
else
  pkill -f "http_server.sh" 2>/dev/null || true
  setsid bash ~/.beaut/site/scripts/http_server.sh \
    > ~/.beaut/state/http.log 2>&1 < /dev/null &
  echo "http server started through setsid (see state/http.log)"
fi

if command -v systemctl >/dev/null 2>&1 \
   && systemctl --user enable beaut-router.service >/dev/null 2>&1 \
   && systemctl --user restart beaut-router.service 2>/dev/null; then
  echo "beaut router service is active"
else
  pkill -f "tcp_router.sh" 2>/dev/null || true
  setsid bash ~/.beaut/site/scripts/tcp_router.sh \
    > ~/.beaut/state/router.log 2>&1 < /dev/null &
  echo "tcp router started through setsid (see state/router.log)"
fi
