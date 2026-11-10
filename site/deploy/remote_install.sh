#!/usr/bin/env bash
# remote_install.sh — runs on the server as SERVICE_USER (after bootstrap).
# Applies the freshly uploaded tree: systemd user service + HTTP server start.
set -euo pipefail

mkdir -p ~/.config/systemd/user
cp -f ~/.beaut/site/deploy/beaut.service ~/.config/systemd/user/beaut.service
# `enable --now` does not restart an already-running unit. An upgrade must
# restart so systemd re-reads ExecStart and the handler picks up the new tree
# instead of keeping the previous release's environment and scripts.
if command -v systemctl >/dev/null 2>&1 \
   && systemctl --user daemon-reload 2>/dev/null \
   && systemctl --user enable beaut.service >/dev/null 2>&1 \
   && systemctl --user restart beaut.service 2>/dev/null; then
  echo "beaut user service is active"
else
  pkill -f "http_server.sh" 2>/dev/null || true
  setsid bash ~/.beaut/site/scripts/http_server.sh \
    > ~/.beaut/state/http.log 2>&1 < /dev/null &
  echo "server started through setsid (see state/http.log)"
fi
