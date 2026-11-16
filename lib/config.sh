# config.sh - load conf.env, then node overrides, then defaults.

load_config() {
  [[ -f "$BEAUT_CONFIG" ]] || die "missing config: $BEAUT_CONFIG"

  # shellcheck source=/dev/null
  . "$BEAUT_CONFIG"

  # A node file overrides only what is local to that machine.
  if [[ -f "$BEAUT_ENV" ]]; then
    # shellcheck source=/dev/null
    . "$BEAUT_ENV"
  fi

  : "${PORT:=8081}"
  : "${HUB_BIND:=0.0.0.0}"
  : "${PUBLIC_URL:=}"
  : "${SITE_DIR:=$BEAUT_ROOT/site}"
  : "${WORKER_NAME:=$(node_name)}"
  : "${WORKER_HOST:=}"
  : "${WORKER_PORT:=8090}"
  : "${WORKER_BIND:=0.0.0.0}"
  : "${TUNNEL_PORT:=}"
  : "${HUB_SSH:=}"
  : "${HUB_RELAY:=}"
  : "${HUB_RELAY_PORT:=18080}"
  : "${ROOT:=$HOME/.beaut}"
  : "${STATE_DIR:=$ROOT/state}"
  : "${LOG_DIR:=$ROOT/logs}"

  if [[ -z "$WORKER_HOST" ]]; then
    WORKER_HOST="$(node_name)"
  fi
}

worker_rows() {
  local row
  for row in "${WORKERS[@]:-}"; do
    [[ -z "$row" || "$row" == \#* ]] && continue
    printf '%s\n' "$row"
  done
}
