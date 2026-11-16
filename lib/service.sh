# service.sh - install and control the per-user systemd units.
#
# Paths come from the running tree (BEAUT_ROOT) and from the loaded config
# (BEAUT_CONFIG, BEAUT_ENV, STATE_DIR, LOG_DIR). Nothing here assumes
# ~/.beaut/app.

unit_dir() { printf '%s/.config/systemd/user' "$HOME"; }

service_prepare() {
  need systemctl
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    die "no user systemd session; log in locally once and enable linger"
  fi
  if command -v loginctl >/dev/null 2>&1; then
    loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || \
      log "warning: could not enable linger; services will stop at logout"
  fi
}

write_unit() {
  local name="$1" template="$2"
  shift 2
  mkdir -p "$(unit_dir)"
  render_template "$BEAUT_ROOT/share/systemd/$template" "$@" >"$(unit_dir)/$name"
}

unit_start() {
  local name="$1" required="${2:-yes}"
  systemctl --user enable "$name" >/dev/null 2>&1 || true
  if ! systemctl --user restart "$name" >/dev/null 2>&1; then
    log "warning: could not restart $name"
  fi
  pause 1
  if systemctl --user is-active --quiet "$name"; then
    log "$name active"
    return 0
  fi

  log "warning: $name is not active"
  if command -v journalctl >/dev/null 2>&1; then
    journalctl --user -u "$name" -n 15 --no-pager >&2 2>/dev/null || true
  fi
  [[ "$required" == yes ]] && return 1
  return 0
}

unit_remove() {
  local name="$1"
  systemctl --user disable --now "$name" >/dev/null 2>&1 || true
  rm -f "$(unit_dir)/$name"
}

service_check() {
  [[ -f "$BEAUT_CONFIG" ]] || die "missing $BEAUT_CONFIG; run deploy.sh first"
  mkdir -p "$STATE_DIR" "$LOG_DIR" || die "cannot create state directories"
}

service_install_hub() {
  local app="$BEAUT_ROOT"
  local bin="$app/bin/beaut-hub"
  local relay_bin="$app/bin/beaut-relay"
  local config="$BEAUT_CONFIG"
  local envfile="$BEAUT_ENV"

  need_exec "$bin"
  service_check

  write_unit beaut-hub.service hub.service \
    BIN "$bin" \
    WORKDIR "$app" \
    CONFIG "$config" \
    ENVFILE "$envfile"

  # A relay is only managed when requested. Leave an existing unit alone when
  # HUB_RELAY is empty so adding the base never breaks an external relay.
  if [[ -n "$HUB_RELAY" ]]; then
    need_exec "$relay_bin"
    write_unit beaut-relay.service relay.service \
      BIN "$relay_bin" \
      CONFIG "$config" \
      ENVFILE "$envfile"
  fi

  systemctl --user daemon-reload
  unit_start beaut-hub.service yes || return 1
  if [[ -n "$HUB_RELAY" ]]; then
    unit_start beaut-relay.service no
  fi
}

service_install_worker() {
  local app="$BEAUT_ROOT"
  local bin="$app/bin/beaut-worker"
  local tunnel_bin="$app/bin/beaut-tunnel"
  local config="$BEAUT_CONFIG"
  local envfile="$BEAUT_ENV"

  need_exec "$bin"
  service_check

  write_unit beaut-worker.service worker.service \
    BIN "$bin" \
    WORKDIR "$app" \
    CONFIG "$config" \
    ENVFILE "$envfile"

  if [[ -n "${TUNNEL_PORT:-}" && -n "${HUB_SSH:-}" ]]; then
    need_exec "$tunnel_bin"
    write_unit beaut-tunnel.service tunnel.service \
      BIN "$tunnel_bin" \
      CONFIG "$config" \
      ENVFILE "$envfile"
  else
    unit_remove beaut-tunnel.service
  fi

  systemctl --user daemon-reload
  unit_start beaut-worker.service yes || return 1
  if [[ -n "${TUNNEL_PORT:-}" && -n "${HUB_SSH:-}" ]]; then
    unit_start beaut-tunnel.service no
  fi
}
