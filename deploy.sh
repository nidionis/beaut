#!/usr/bin/env bash
# deploy.sh - install beaut on machines that are already reachable by SSH.
#
# No bootstrap, no sudo, no password handling. Run it from the hub checkout:
# the hub installs locally, workers are installed over SSH. The script uploads
# the tree, writes a small node file and installs user systemd units.
set -euo pipefail

SRC="$(cd -- "$(dirname -- "$0")" && pwd)"
CONFIG="${BEAUT_CONFIG:-$SRC/conf.env}"

log() { printf '[deploy] %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

[[ -f "$CONFIG" ]] || die "missing config: $CONFIG"
# shellcheck source=/dev/null
. "$CONFIG"

if ! declare -p WORKERS >/dev/null 2>&1; then
  WORKERS=()
fi
: "${SSH_USER:=}"
: "${HUB_SSH:=}"
: "${HUB_RELAY:=}"
: "${HUB_RELAY_PORT:=18080}"
: "${PUBLIC_URL:=}"

SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o StrictHostKeyChecking=accept-new
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=3
  -o LogLevel=ERROR
)

worker_rows() {
  local row
  for row in "${WORKERS[@]:-}"; do
    [[ -z "$row" || "$row" == \#* ]] && continue
    printf '%s\n' "$row"
  done
}

ssh_run() {
  local target="$1"
  shift
  ssh "${SSH_OPTS[@]}" "$target" "$@"
}

run_local() {
  bash -c "$*"
}

run_on() {
  local target="$1"
  shift
  if [[ "$target" == local ]]; then
    run_local "$*"
  else
    ssh_run "$target" "$*"
  fi
}

env_line() {
  printf '%s=%q\n' "$1" "$2"
}

stop_services() {
  local target="$1" scope="$2"
  case "$scope" in
    hub)
      run_on "$target" 'systemctl --user stop beaut-hub.service >/dev/null 2>&1 || true'
      ;;
    worker)
      run_on "$target" 'systemctl --user stop beaut-worker.service beaut-tunnel.service >/dev/null 2>&1 || true'
      ;;
  esac
}

deploy_code() {
  local target="$1" dest="$HOME/.beaut/app" label="$1"
  [[ "$label" == local ]] && label="this machine"
  log "copying source to $label:~/.beaut/app"

  if [[ "$target" == local ]]; then
    mkdir -p "$dest"
    tar -xzf "$ARCHIVE" -C "$dest"
    if [[ ! "$CONFIG" -ef "$dest/conf.env" ]]; then
      cp -- "$CONFIG" "$dest/conf.env"
    fi
    chmod +x "$dest/beaut" "$dest/deploy.sh" "$dest"/bin/beaut-*
    return
  fi

  ssh_run "$target" 'mkdir -p ~/.beaut/app'
  ssh "${SSH_OPTS[@]}" "$target" 'tar -xzf - -C ~/.beaut/app' <"$ARCHIVE"
  ssh "${SSH_OPTS[@]}" "$target" 'cat > ~/.beaut/app/conf.env' <"$CONFIG"
  ssh_run "$target" 'chmod +x ~/.beaut/app/beaut ~/.beaut/app/deploy.sh ~/.beaut/app/bin/beaut-*'
}

write_node_env() {
  local target="$1" body="$2"
  if [[ "$target" == local ]]; then
    umask 077
    mkdir -p "$HOME/.beaut"
    printf '%s\n' "$body" >"$HOME/.beaut/node.env"
    return
  fi
  printf '%s\n' "$body" | ssh "${SSH_OPTS[@]}" "$target" \
    'umask 077; mkdir -p ~/.beaut; cat > ~/.beaut/node.env'
}

run_service_install() {
  local target="$1" scope="$2"
  run_on "$target" \
    "cd ~/.beaut/app && BEAUT_CONFIG=~/.beaut/app/conf.env BEAUT_ENV=~/.beaut/node.env ./beaut service install $scope"
}

deploy_hub() {
  log "hub -> this machine"
  stop_services local hub
  deploy_code local
  run_service_install local hub
}

deploy_worker() {
  local name="$1" host="$2" port="$3" target="$4" tunnel="$5"
  local body

  log "worker $name -> ${target/local/this machine} (${host}:${port}${tunnel:+, tunnel $tunnel})"

  body="$(
    env_line WORKER_NAME "$name"
    env_line WORKER_HOST "$host"
    env_line WORKER_PORT "$port"
    env_line TUNNEL_PORT "$tunnel"
    env_line HUB_SSH "$HUB_SSH"
  )"

  stop_services "$target" worker
  deploy_code "$target"
  write_node_env "$target" "$body"
  run_service_install "$target" worker
}

selector="${1:-all}"
case "$selector" in
  all|hub|workers) ;;
  -h|--help)
    printf 'usage: %s [all|hub|workers|WORKER]\n' "$0"
    exit 0
    ;;
  *)
    found=0
    while IFS='|' read -r name _; do
      [[ "$name" == "$selector" ]] && found=1
    done < <(worker_rows)
    (( found == 1 )) || die "unknown target: $selector"
    ;;
esac

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/beaut-deploy.XXXXXX")"
ARCHIVE="$TMP_DIR/tree.tar.gz"
trap 'rm -rf "$TMP_DIR"' EXIT

log "packing $SRC"
tar -C "$SRC" -czf "$ARCHIVE" \
  --exclude='./.git' --exclude='./.git/*' \
  --exclude='./context' --exclude='./context/*' \
  --exclude='./.svr' --exclude='./.svr/*' \
  --exclude='./.idea' --exclude='./.idea/*' \
  --exclude='./.junie' --exclude='./.junie/*' \
  --exclude='./conf.env' \
  --exclude='./state' --exclude='./logs' \
  --exclude='./tags' \
  --exclude='./tests/.build' \
  --exclude='*.lock' --exclude='*.swp' --exclude='*.tmp' \
  .

if [[ "$selector" == all || "$selector" == hub ]]; then
  deploy_hub
fi

if [[ "$selector" != hub ]]; then
  matched=0
  while IFS='|' read -r name host port ssh tunnel; do
    [[ -n "$name" ]] || continue
    if [[ "$selector" != all && "$selector" != workers && "$name" != "$selector" ]]; then
      continue
    fi
    matched=1
    port="${port:-8090}"
    target="${ssh:-${SSH_USER:+$SSH_USER@}$host}"
    [[ "$target" == local ]] && tunnel=""
    if [[ -n "$tunnel" && -z "$HUB_SSH" ]]; then
      log "warning: HUB_SSH is empty, reverse tunnel disabled for $name"
      tunnel=""
    fi
    deploy_worker "$name" "$host" "$port" "$target" "$tunnel"
  done < <(worker_rows)
  if [[ "$selector" != all && "$selector" != workers ]] && (( matched == 0 )); then
    die "target not found: $selector"
  fi
fi

log "done"
if [[ -n "$PUBLIC_URL" ]]; then
  log "public: $PUBLIC_URL"
fi
