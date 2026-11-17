# config.sh - load conf.env, then node overrides, then defaults.

load_config() {
  [[ -f "$BEAUT_CONFIG" ]] || die "missing config: $BEAUT_CONFIG"

  # shellcheck source=/dev/null
  . "$BEAUT_CONFIG"

  if [[ -f "$BEAUT_ENV" ]]; then
    # shellcheck source=/dev/null
    . "$BEAUT_ENV"
  fi

  : "${NAME:=beaut}"
  : "${ADMIN_USER:=${NAME:-master}}"
  : "${WORKER_USER:=worker}"
  : "${HUB:=10.66.0.1}"
  : "${PUBLIC_URL:=}"

  : "${PORT:=8081}"
  : "${WORK_PORT:=8090}"
  : "${WORKER_PORT:=8091}"
  : "${HUB_BIND:=0.0.0.0}"
  : "${WORK_BIND:=0.0.0.0}"
  : "${WORKER_BIND:=0.0.0.0}"

  : "${REPORT_DELAY:=60}"
  : "${HEARTBEAT_DELAY:=5}"
  : "${BACKUP_DELAY:=60}"
  : "${DEATH_TIME:=10}"
  : "${RETAIN_SNAPSHOTS:=7}"

  : "${MIN_CPU:=1}"
  : "${MIN_RAM_KB:=262144}"
  : "${MIN_DISK_KB:=1048576}"

  : "${ROOT:=$HOME/.beaut}"
  : "${APP_DIR:=$ROOT/app}"
  : "${STATE_DIR:=$ROOT/state}"
  : "${LOG_DIR:=$ROOT/logs}"
  : "${CONTAINER_DIR:=$ROOT/containers}"
  : "${SNAPSHOT_DIR:=$ROOT/snapshots}"
  : "${SITE_DIR:=$BEAUT_ROOT/site}"
  : "${WORK_DIR:=$BEAUT_ROOT/work}"

  : "${CONF_DIR:=$BEAUT_CONF_DIR}"
  : "${WORKERS_DIR:=$CONF_DIR/workers}"
  : "${KEYS_DIR:=$CONF_DIR/keys}"
  : "${NODE_KEY:=$KEYS_DIR/node}"
  : "${NODE_ROLE:=hub}"
  : "${NODE_ADDRESS:=}"
  : "${NODE_HASH:=}"
  : "${DOCKER_CMD:=sudo docker}"

  : "${HTTP_MAX_BODY:=10737418240}"
  : "${WORKER_TARGET:=}"
  : "${WORKER_ADDRESS:=}"
  : "${SSH_USER:=}"
  : "${SSH_OPTS:=-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o LogLevel=ERROR}"

  if ! declare -p SCHEDULING_PRIO >/dev/null 2>&1; then
    SCHEDULING_PRIO=(cpu ram disk)
  fi

  if [[ -z "$NODE_HASH" && -f "$NODE_KEY.pub" ]]; then
    NODE_HASH="$(worker_hash "$NODE_KEY.pub" || true)"
  fi
}

validate_config() {
  is_uint "$PORT" || die "invalid PORT: $PORT"
  is_uint "$WORK_PORT" || die "invalid WORK_PORT: $WORK_PORT"
  is_uint "$WORKER_PORT" || die "invalid WORKER_PORT: $WORKER_PORT"
  is_uint "$REPORT_DELAY" || die "invalid REPORT_DELAY: $REPORT_DELAY"
  is_uint "$HEARTBEAT_DELAY" || die "invalid HEARTBEAT_DELAY: $HEARTBEAT_DELAY"
  is_uint "$BACKUP_DELAY" || die "invalid BACKUP_DELAY: $BACKUP_DELAY"
  is_uint "$DEATH_TIME" || die "invalid DEATH_TIME: $DEATH_TIME"
  is_uint "$MIN_CPU" || die "invalid MIN_CPU: $MIN_CPU"
  is_uint "$MIN_RAM_KB" || die "invalid MIN_RAM_KB: $MIN_RAM_KB"
  is_uint "$MIN_DISK_KB" || die "invalid MIN_DISK_KB: $MIN_DISK_KB"
  is_uint "$RETAIN_SNAPSHOTS" || die "invalid RETAIN_SNAPSHOTS: $RETAIN_SNAPSHOTS"
  (( RETAIN_SNAPSHOTS >= 1 )) || die "RETAIN_SNAPSHOTS must be at least 1"
  is_uint "$HTTP_MAX_BODY" || die "invalid HTTP_MAX_BODY: $HTTP_MAX_BODY"
  case "$NODE_ROLE" in
    hub|worker) ;;
    *) die "invalid NODE_ROLE: $NODE_ROLE" ;;
  esac
  if [[ "$NODE_ROLE" == worker ]]; then
    [[ -n "$NODE_ADDRESS" ]] || die "NODE_ADDRESS is empty (set the worker's explicit address)"
    case "$NODE_ADDRESS" in
      localhost|127.*|::1|"[::1]") die "NODE_ADDRESS must be an explicit non-loopback address" ;;
    esac
  fi
  [[ -n "$HUB" ]] || die "HUB is empty"
  case "$HUB" in
    localhost|127.*|::1|"[::1]") die "HUB must be an explicit non-loopback address" ;;
  esac
  [[ -n "$ROOT" ]] || die "ROOT is empty"
  (( ${#SCHEDULING_PRIO[@]} > 0 )) || die "SCHEDULING_PRIO is empty"

  local item
  for item in "${SCHEDULING_PRIO[@]}"; do
    case "$item" in
      cpu|ram|disk) ;;
      *) die "unknown SCHEDULING_PRIO item: $item" ;;
    esac
  done
}

# scheduling_prio_json - render SCHEDULING_PRIO as a JSON array for jq.
scheduling_prio_json() {
  local item first=yes
  printf '['
  for item in "${SCHEDULING_PRIO[@]}"; do
    [[ "$first" == yes ]] || printf ','
    first=no
    printf '"%s"' "$item"
  done
  printf ']'
}
