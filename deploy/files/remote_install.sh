#!/usr/bin/env bash
# remote_install.sh — runs on the server as SERVICE_USER (after bootstrap).
# Applies the freshly uploaded tree: systemd user service + HTTP server start.
set -euo pipefail

mkdir -p ~/.config/systemd/user
cp -f ~/.beaut/deploy/files/beaut.service ~/.config/systemd/user/beaut.service
if command -v systemctl >/dev/null 2>&1 \
   && systemctl --user daemon-reload 2>/dev/null \
   && systemctl --user enable --now beaut.service 2>/dev/null; then
  echo "beaut user service is active"
else
  pkill -f "http_server.sh" 2>/dev/null || true
  setsid bash ~/.beaut/deploy/files/start.sh \
    > ~/.beaut/state/http.log 2>&1 < /dev/null &
  echo "server started through setsid (see state/http.log)"
fi
