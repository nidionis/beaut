#!/usr/bin/env bash
# install.sh — beaut single entry point (the only user-facing script besides config.env)
#
#   ./install.sh                    install using config.env
#   ./install.sh --role R [IP]      non-interactive install (comma list: orchestrator,router,worker,client)
#   ./install.sh --status           show what is installed and whether it runs
#   ./install.sh --uninstall        remove the installed CLI (state is kept)
#   ./install.sh --serve [PORT]     publish a bootstrap tarball (curl | bash)
#   ./install.sh deploy [ORCH_IP]   SFTP + install on the orchestrator via ssh
#   ./install.sh --help
#
# Required in config.env: BEAUT_PASSWORD, ROLE.
# Layout (all user-writable, no root needed):
#   $BIN_DIR/$NAME               the CLI          (default ~/.bin, added to ~/.bashrc)
#   $PREFIX/lib/$NAME/$NAME-bin  the C tool       (internal)
#   $PREFIX/lib/$NAME/beaut-lib  shared shell lib
#   $PREFIX/etc/$NAME.conf       config + runtime keys (mode 0600)
#   $PREFIX/var/                 log.enc, connections.log, archive/
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
# shellcheck source=scripts/lib.sh
. "$HERE/scripts/lib.sh"

detect_if() {
  ip route get 1.1.1.1 2>/dev/null \
    | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}' \
    || echo lo
}

# ensure_path — add $BIN_DIR to ~/.bashrc once (idempotent, no duplicate lines)
ensure_path() {
  local rc="${BASHRC:-$HOME/.bashrc}" line
  line="export PATH=\"$BIN_DIR:\$PATH\""
  if grep -qF "$BIN_DIR" "$rc" 2>/dev/null; then
    info "$BIN_DIR already referenced in $rc"
    return 0
  fi
  touch "$rc"
  printf '\n# beaut: make %s available\n%s\n' "$NAME" "$line" >> "$rc"
  info "PATH entry added to $rc"
}

do_install() {
  local role="$1" orch_ip="${2:-}" domain

  if [ -f config.env ]; then load_config config.env; fi
  ROLE="$(norm_roles "$role")"
  validate_roles "$ROLE" || die "unknown ROLE: $role (orchestrator|router|worker|client)"
  if role_has "$ROLE" orchestrator; then orch_ip="127.0.0.1"; fi
  [ -n "$orch_ip" ] || die "$ROLE needs an orchestrator IP (arg 2 or IP_ORCHESTRATOR in config.env)"
  : "${BEAUT_PASSWORD:?BEAUT_PASSWORD is required}"
  export ROLE ORCH_IP="$orch_ip"

  # advertised domain: router → vm, worker → worker, otherwise first cap
  if role_has "$ROLE" router; then domain=vm
  elif role_has "$ROLE" worker; then domain=worker
  else domain="$(printf '%s' "$ROLE" | cut -d' ' -f1)"
  fi
  export BEAUT_DOMAIN="$domain"

  resolve_paths
  BEAUT_IF="${BEAUT_IF:-$(detect_if)}"
  log "install $NAME ($ROLE) -> $PREFIX"

  bash "$HERE/scripts/build.sh"

  install -d -m 0755 "$BIN_DIR" "$LIB_DIR" "$ENV_DIR"
  install -d -m 0755 "$STATE_DIR" "$STATE_DIR/archive"

  # migrate from the old $PREFIX/bin layout
  if [ "$BIN_DIR" != "$PREFIX/bin" ] && [ -f "$PREFIX/bin/$NAME" ]; then
    rm -f "$PREFIX/bin/$NAME"
    rmdir "$PREFIX/bin" 2>/dev/null || true
    info "migrated old $PREFIX/bin/$NAME"
  fi

  # the C tool lives outside PATH: only $NAME is exposed
  install -m 0755 "$HERE/bin/beaut" "$TOOL"

  # config carries the password => 0600
  install -m 0600 config.env "$CONF"
  conf_set "$CONF" BEAUT_NAME      "$NAME"
  conf_set "$CONF" BEAUT_PREFIX    "$PREFIX"
  conf_set "$CONF" BEAUT_BIN_DIR   "$BIN_DIR"
  conf_set "$CONF" BEAUT_LIB_DIR   "$LIB_DIR"
  conf_set "$CONF" BEAUT_ENV_DIR   "$ENV_DIR"
  conf_set "$CONF" BEAUT_STATE_DIR "$STATE_DIR"
  conf_set "$CONF" BEAUT_ETC_DIR   "$ENV_DIR"
  conf_set "$CONF" ROLE            "$ROLE"
  conf_set "$CONF" BEAUT_CAPS      "$ROLE"
  conf_set "$CONF" BEAUT_LOCAL_ORCH 1
  conf_set "$CONF" BEAUT_DOMAIN    "$domain"
  conf_set "$CONF" BEAUT_IF        "$BEAUT_IF"
  conf_set "$CONF" BEAUT_HEARTBEAT_S "${BEAUT_HEARTBEAT_S:-30}"
  conf_set "$CONF" BEAUT_POLL_S      "${BEAUT_POLL_S:-3}"
  conf_set "$CONF" BEAUT_STALE_S     "${BEAUT_STALE_S:-90}"
  conf_set "$CONF" BEAUT_ALLOW_EXEC  "${BEAUT_ALLOW_EXEC:-0}"
  conf_set "$CONF" BEAUT_EXEC_DOMAINS "${BEAUT_EXEC_DOMAINS:-}"
  conf_set "$CONF" BEAUT_EXEC_TIMEOUT_S "${BEAUT_EXEC_TIMEOUT_S:-300}"
  conf_set "$CONF" BEAUT_NICE            "${BEAUT_NICE:-10}"
  conf_set "$CONF" BEAUT_MAX_CONCURRENT  "${BEAUT_MAX_CONCURRENT:-1}"
  conf_set "$CONF" BEAUT_RATE_LIMIT      "${BEAUT_RATE_LIMIT:-60}"
  conf_set "$CONF" BEAUT_ABUSE_ACTION    "${BEAUT_ABUSE_ACTION:-nice}"
  conf_set "$CONF" SCHEDULER_RESERVE_NODES "${SCHEDULER_RESERVE_NODES:-0}"
  conf_set "$CONF" ORCHESTRATOR_IP   "$orch_ip"

  # the C tool reads these from the environment
  export BEAUT_STATE_DIR="$STATE_DIR" BEAUT_ETC_DIR="$ENV_DIR"
  export BEAUT_IF

  # runtime scripts
  render templates/beaut-lib.sh.tmpl "$LIB_DIR/beaut-lib"
  chmod 0644 "$LIB_DIR/beaut-lib"
  render templates/beaut-cli.sh.tmpl "$BIN_DIR/$NAME"
  chmod 0755 "$BIN_DIR/$NAME"

  ensure_path

  # first identity: bootstrap the admin if priv.tsv is empty
  if [ ! -s "$ENV_DIR/priv.tsv" ]; then
    log "bootstrapping admin identity"
    local id
    id="$("$TOOL" myid "$BEAUT_PASSWORD")"
    "$TOOL" join "$ENV_DIR/pending.tsv" "$BEAUT_PASSWORD" >/dev/null 2>&1 || true
    if [ -n "$id" ]; then
      "$TOOL" approve "$ENV_DIR/pending.tsv" "$ENV_DIR/priv.tsv" "$id" 3
      chmod 0600 "$ENV_DIR/priv.tsv"
      log "admin id=$id level=3"
    fi
  fi

  echo
  log "done — $BIN_DIR/$NAME"
  info "config: $CONF (0600)"
  info "state:  $STATE_DIR"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR is not in this shell's PATH — run: exec bash -l" ;;
  esac
}

do_status() {
  source_config
  resolve_paths
  local c=""
  if [ -r "$CONF" ]; then c="$CONF"; fi
  local role="" allow="" domain="" caps=""
  if [ -n "$c" ]; then
    role="$(sed -n 's/^ROLE=//p' "$c" | head -1 | sed 's/#.*//; s/["[:space:]]//g')"
    caps="$(sed -n 's/^BEAUT_CAPS=//p' "$c" | head -1 | sed 's/#.*//; s/["[:space:]]//g')"
    domain="$(sed -n 's/^BEAUT_DOMAIN=//p' "$c" | head -1 | sed 's/#.*//; s/["[:space:]]//g')"
    allow="$(sed -n 's/^BEAUT_ALLOW_EXEC=//p' "$c" | head -1 | sed 's/#.*//; s/["[:space:]]//g')"
  fi
  printf '%-9s %s\n' "name:" "$NAME"
  printf '%-9s %s\n' "role:" "${role:-?} (caps=${caps:-?}, domain=${domain:-?}, allow_exec=${allow:-?})"
  printf '%-9s %s %s\n' "cli:" "$BIN_DIR/$NAME" "$([ -x "$BIN_DIR/$NAME" ] && echo ok || echo MISSING)"
  printf '%-9s %s %s\n' "tool:" "$TOOL" "$([ -x "$TOOL" ] && echo ok || echo MISSING)"
  printf '%-9s %s\n' "config:" "$CONF"
  printf '%-9s %s\n' "state:" "$STATE_DIR"
  if pgrep -f -- "$BIN_DIR/$NAME watch" >/dev/null 2>&1; then
    printf '%-9s %s\n' "process:" "watch running"
  else
    printf '%-9s %s\n' "process:" "not running (beaut watch)"
  fi
  if [ -f "$STATE_DIR/connections.log" ]; then
    printf '%-9s\n' "recent:"
    tail -n 5 "$STATE_DIR/connections.log" | sed 's/^/          /'
  fi
  command -v "$NAME" >/dev/null 2>&1 \
    || warn "$NAME is not in PATH (add $BIN_DIR)"
}

do_uninstall() {
  source_config
  resolve_paths
  pkill -TERM -f -- "$BIN_DIR/$NAME watch" 2>/dev/null || true
  sleep 1
  pkill -f "$TOOL" 2>/dev/null || true
  rm -f "$BIN_DIR/$NAME" "$TOOL" "$LIB_DIR/beaut-lib"
  rmdir "$LIB_DIR" 2>/dev/null || true
  if [ "$(id -u)" = 0 ]; then
    rm -f /etc/systemd/system/beaut-*.service /etc/systemd/system/beaut-*.timer
    systemctl daemon-reload 2>/dev/null || true
  fi
  log "removed $NAME and its tool — state kept in $STATE_DIR"
}

do_serve() {
  local port="${1:-8080}" d ip
  d="$(mktemp -d)"
  cp install.sh config.env Makefile "$d/"
  cp -r scripts templates src "$d/"
  tar czf "$d/beaut.tgz" -C "$d" install.sh config.env Makefile scripts templates src
  ( cd "$d" && sha256sum beaut.tgz > beaut.tgz.sha256 && chmod 644 ./* 2>/dev/null || true )
  ip="$(local_ip)"
  echo "$ip" > "$d/orch.host"
  log "serving on :$port — sha256 $(cut -d' ' -f1 "$d/beaut.tgz.sha256" | cut -c1-16)…"
  cat <<EOT

  on the new node (verify before running):
    curl -fsSLO http://$ip:$port/beaut.tgz
    curl -fsSL  http://$ip:$port/beaut.tgz.sha256 | sha256sum -c -
    tar xzf beaut.tgz && ./install.sh

EOT
  exec python3 -m http.server "$port" --directory "$d"
}

case "${1:-}" in
  --role)
    shift
    [ "$#" -ge 1 ] || die "usage: $0 --role ROLE [ORCH_IP]"
    do_install "$1" "${2:-}"
    ;;
  --status)    do_status ;;
  --uninstall) do_uninstall ;;
  --serve)     shift; do_serve "$@" ;;
  deploy)      shift; bash "$HERE/scripts/deploy.sh" "$@" ;;
  --help|-h)   sed -n '2,18p' "$0"; exit 0 ;;
  "")
    load_config config.env
    do_install "$ROLE" "${IP_ORCHESTRATOR:-}"
    ;;
  *)
    load_config config.env
    do_install "$ROLE" "${IP_ORCHESTRATOR:-}"
    ;;
esac
