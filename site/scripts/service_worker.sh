#!/usr/bin/env bash
# service_worker.sh — claim one service lease, run its compose app, heartbeat.
#
# Run on a worker:
#   curl -fsS http://<server>:<port>/scripts/service_worker.sh | bash -s -- <name>
#
# The server manifest is $SVR_ROOT/service/<name>/ (ports, compose file). The
# worker needs docker compose, git, rsync and SSH access to the server.
set -uo pipefail

name="${1:-}"
if [[ -z "$name" ]]; then
  printf 'usage: service_worker.sh <service>\n' >&2
  exit 2
fi

BEAUT_URL="${BEAUT_URL:-}"
SERVICE_SSH="${SERVICE_SSH:-}"
SVR_ROOT="${SVR_ROOT:-$HOME/.svr}"
SERVICE_STATE_LOCAL="${SERVICE_STATE_LOCAL:-$HOME/.beaut/state/services/$name/state}"
SERVICE_REMOTE_STATE="${SERVICE_REMOTE_STATE:-.beaut/state/services/$name/state}"
SERVICE_HEARTBEAT_SECONDS="${SERVICE_HEARTBEAT_SECONDS:-5}"
SERVICE_SYNC_SECONDS="${SERVICE_SYNC_SECONDS:-30}"
SERVICE_RETRY_SECONDS="${SERVICE_RETRY_SECONDS:-5}"
SERVICE_SSH_PORT="${SERVICE_SSH_PORT:-}"
WORKER_ADDRESS="${WORKER_ADDRESS:-}"

SSH_OPTIONS=()
RSYNC_SHELL="ssh"
if [[ -n "$SERVICE_SSH_PORT" ]]; then
  SSH_OPTIONS=(-p "$SERVICE_SSH_PORT")
  RSYNC_SHELL="ssh -p $SERVICE_SSH_PORT"
fi

log() { printf '[service:%s] %s\n' "$name" "$*" >&2; }
has() { command -v "$1" >/dev/null 2>&1; }
ssh_remote() { ssh "${SSH_OPTIONS[@]}" "$SERVICE_SSH" "$@"; }

[[ -n "$BEAUT_URL" ]] || { log "set BEAUT_URL to the server URL"; exit 1; }
if [[ -z "$SERVICE_SSH" ]]; then
  server_host="${BEAUT_URL#*://}"
  server_host="${server_host%%/*}"
  server_host="${server_host%%:*}"
  SERVICE_SSH="${SERVICE_USER:-beaut}@$server_host"
fi
if [[ -z "${SVR_REMOTE:-}" ]]; then
  if [[ -n "$SERVICE_SSH_PORT" ]]; then
    SVR_REMOTE="ssh://$SERVICE_SSH:$SERVICE_SSH_PORT/~/.svr"
  else
    SVR_REMOTE="$SERVICE_SSH:.svr"
  fi
fi

http_post() {
  local path="$1" data="$2" response
  response="$(mktemp)" || return 1
  HTTP_STATUS="$(curl -sS --connect-timeout 3 --max-time 5 -o "$response" -w '%{http_code}' \
    -X POST --data-binary "$data" "$BEAUT_URL$path" 2>/dev/null)" || {
    rm -f -- "$response"
    return 1
  }
  HTTP_BODY="$(cat "$response")"
  rm -f -- "$response"
}

sync_repo() {
  if [[ -d "$SVR_ROOT/.git" ]]; then
    git -C "$SVR_ROOT" pull --ff-only --quiet >/dev/null 2>&1 \
      || log "git pull failed; using the local checkout"
  elif [[ ! -d "$SVR_ROOT/service/$name" ]]; then
    has git || { log "git is required to clone $SVR_REMOTE"; return 1; }
    git clone --quiet "$SVR_REMOTE" "$SVR_ROOT" || return 1
  fi
  [[ -d "$SVR_ROOT/service/$name" ]] || {
    log "missing service directory: $SVR_ROOT/service/$name"
    return 1
  }
}

compose_file() {
  local candidate
  for candidate in compose.yml compose.yaml docker-compose.yml docker-compose.yaml; do
    [[ -f "$SVR_ROOT/service/$name/$candidate" ]] && {
      printf '%s' "$SVR_ROOT/service/$name/$candidate"
      return 0
    }
  done
  return 1
}

compose_select() {
  if has docker && docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
  elif has docker-compose; then
    COMPOSE=(docker-compose)
  else
    log "docker compose is required"
    return 1
  fi
}

compose_up() {
  SERVICE_STATE="$SERVICE_STATE_LOCAL" COMPOSE_PROJECT_NAME="$project_name" \
    "${COMPOSE[@]}" -f "$compose" up -d
}

compose_down() {
  SERVICE_STATE="$SERVICE_STATE_LOCAL" COMPOSE_PROJECT_NAME="$project_name" \
    "${COMPOSE[@]}" -f "$compose" down --remove-orphans
}

restore_state() {
  mkdir -p -- "$SERVICE_STATE_LOCAL" || return 1
  ssh_remote "mkdir -p '$SERVICE_REMOTE_STATE'" >/dev/null 2>&1 \
    || { log "cannot reach server state"; return 1; }
  rsync -az --delete -e "$RSYNC_SHELL" \
    "$SERVICE_SSH:$SERVICE_REMOTE_STATE/" "$SERVICE_STATE_LOCAL/" \
    || { log "state restore failed"; return 1; }
}

sync_state() {
  rsync -az --delete -e "$RSYNC_SHELL" \
    "$SERVICE_STATE_LOCAL/" "$SERVICE_SSH:$SERVICE_REMOTE_STATE/"
}

cleanup() {
  trap - EXIT
  if [[ "${running:-0}" == "1" ]]; then
    compose_down || true
    if [[ "${lease_lost:-0}" == "0" ]]; then
      sync_state || log "final state sync failed"
    fi
  fi
  if [[ "${claimed:-0}" == "1" ]]; then
    http_post "/service/$name/release" "worker=$WORKER_ADDRESS" || true
  fi
}
trap 'exit 0' INT TERM
trap cleanup EXIT

worker_address() {
  local server_host
  server_host="${BEAUT_URL#*://}"
  server_host="${server_host%%/*}"
  server_host="${server_host%%:*}"
  if has ip; then
    ip -4 route get "$server_host" 2>/dev/null \
      | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }'
  fi
}

if [[ -z "$WORKER_ADDRESS" ]]; then
  WORKER_ADDRESS="$(worker_address)"
fi
if [[ -z "$WORKER_ADDRESS" ]]; then
  WORKER_ADDRESS="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
[[ -n "$WORKER_ADDRESS" ]] || { log "set WORKER_ADDRESS"; exit 1; }

has curl || { log "curl is required"; exit 1; }
has rsync || { log "rsync is required"; exit 1; }
sync_repo || exit 1
compose="$(compose_file)" || { log "no compose file for $name"; exit 1; }
compose_select || exit 1
project_name="beaut-${name,,}"
project_name="${project_name//[^a-z0-9_-]/_}"

while :; do
  if ! http_post "/service/$name/claim" "worker=$WORKER_ADDRESS"; then
    log "server unreachable; retrying"
    sleep "$SERVICE_RETRY_SECONDS"
    continue
  fi
  case "$HTTP_STATUS" in
    200) claimed=1; log "lease acquired"; break ;;
    409) log "standby: lease held"; sleep "$SERVICE_RETRY_SECONDS" ;;
    404) log "no ports manifest on the server"; exit 1 ;;
    400) log "claim rejected: $HTTP_BODY"; exit 1 ;;
    *) log "claim failed: $HTTP_STATUS $HTTP_BODY"; sleep "$SERVICE_RETRY_SECONDS" ;;
  esac
done

sync_repo || { log "cannot refresh the service checkout"; exit 1; }
compose="$(compose_file)" || { log "no compose file for $name"; exit 1; }
restore_state || exit 1
if ! compose_up; then
  log "compose up failed"
  compose_down || true
  exit 1
fi
running=1
last_sync="$(date +%s)"
misses=0

while :; do
  sleep "$SERVICE_HEARTBEAT_SECONDS"
  if ! http_post "/service/$name/heartbeat" "worker=$WORKER_ADDRESS"; then
    misses=$((misses + 1))
    (( misses >= 3 )) && { lease_lost=1; log "server unreachable; stopping"; break; }
    continue
  fi
  misses=0
  if [[ "$HTTP_STATUS" != "200" ]]; then
    lease_lost=1
    log "lease lost; stopping"
    break
  fi
  now="$(date +%s)"
  if (( now - last_sync >= SERVICE_SYNC_SECONDS )); then
    sync_state || log "state sync failed"
    last_sync="$now"
  fi
done
