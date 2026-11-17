#!/usr/bin/env bash
# smoke.sh - end-to-end check of the minimal fabric.
#
# TEST_ADDRESS must be an explicit, reachable address. localhost and loopback
# are rejected on purpose: the runtime never uses them.
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_ADDRESS="${TEST_ADDRESS:-}"
BUILD="${TEST_BUILD_DIR:-$ROOT_DIR/tests/.build/smoke}"
DOCKER_CMD="${TEST_DOCKER_CMD:-docker}"
BASE_PORT="${TEST_BASE_PORT:-$((20000 + ($$ % 20000)))}"
HUB_PORT="$BASE_PORT"
WORK_PORT="$((BASE_PORT + 1))"
W1_PORT="$((BASE_PORT + 2))"
W2_PORT="$((BASE_PORT + 3))"
APP_PORT="$((BASE_PORT + 4))"

HUB_PID=""
WORK_PID=""
W1_PID=""
W2_PID=""
JOB_IDS=()

# shellcheck source=../lib/common.sh
. "$ROOT_DIR/lib/common.sh"

usage_error() {
  printf 'smoke: %s\n' "$*" >&2
  exit 2
}

case "$TEST_ADDRESS" in
  "") usage_error "set TEST_ADDRESS to the machine's explicit address" ;;
  localhost|127.*|::1|"[::1]") usage_error "TEST_ADDRESS must not be loopback" ;;
esac

for cmd in curl jq socat tar ssh-keygen "${DOCKER_CMD%% *}"; do
  command -v "$cmd" >/dev/null 2>&1 || usage_error "missing dependency: $cmd"
done

cleanup() {
  local rc=$? pid
  trap - EXIT
  for pid in "$W1_PID" "$W2_PID" "$WORK_PID" "$HUB_PID"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  for pid in "${JOB_IDS[@]}"; do
    "$DOCKER_CMD" rm -f "beaut-$pid" >/dev/null 2>&1 || true
    "$DOCKER_CMD" image rm -f "beaut-$pid" >/dev/null 2>&1 || true
  done
  if (( rc == 0 )); then
    rm -rf -- "$BUILD"
  else
    printf '\n--- hub.log ---\n' >&2
    tail -40 "$BUILD/hub.log" >&2 2>/dev/null || true
    printf '\n--- work.log ---\n' >&2
    tail -20 "$BUILD/work.log" >&2 2>/dev/null || true
    printf '\n--- w1.log ---\n' >&2
    tail -40 "$BUILD/w1.log" >&2 2>/dev/null || true
    printf '\n--- w2.log ---\n' >&2
    tail -40 "$BUILD/w2.log" >&2 2>/dev/null || true
    printf '\nsmoke: build kept at %s\n' "$BUILD" >&2
  fi
  exit "$rc"
}
trap cleanup EXIT

render_node() {
  local out="$1" role="$2" root="$3" worker_port="$4"
  render_template "$ROOT_DIR/tests/fixtures/smoke.env" \
    ADDRESS "$TEST_ADDRESS" \
    ROLE "$role" \
    ROOT "$root" \
    HUB_PORT "$HUB_PORT" \
    WORK_PORT "$WORK_PORT" \
    WORKER_PORT "$worker_port" \
    DOCKER_CMD "$DOCKER_CMD" >"$out"
}

wait_http() {
  local url="$1" tries="${2:-300}" i
  for ((i = 0; i < tries; i++)); do
    if curl -fsS --noproxy '*' --max-time 1 "$url" >/dev/null 2>&1; then
      return 0
    fi
    pause 0.2
  done
  printf 'smoke: timeout waiting for %s\n' "$url" >&2
  return 1
}

hub_status() {
  curl -fsS --noproxy '*' --max-time 5 "http://$TEST_ADDRESS:$HUB_PORT/status"
}

wait_workers() {
  local want="$1" tries="${2:-100}" i count
  for ((i = 0; i < tries; i++)); do
    count="$(hub_status 2>/dev/null |
      jq '[.workers[] | select(.online and (.resources.cpus // 0) > 0)] | length' \
        2>/dev/null || printf 0)"
    [[ "$count" == "$want" ]] && return 0
    pause 0.2
  done
  printf 'smoke: timeout waiting for %s online workers\n' "$want" >&2
  return 1
}

job_field() {
  local id="$1" field="$2"
  BEAUT_CONFIG="$BUILD/hub/conf/conf.env" "$ROOT_DIR/beaut" jobs |
    jq -r --arg id "$id" --arg field "$field" \
      '.[] | select(.id == $id) | getpath($field | split(".")) // empty'
}

wait_job() {
  local id="$1" filter="$2" what="$3" tries="${4:-300}" i
  for ((i = 0; i < tries; i++)); do
    if BEAUT_CONFIG="$BUILD/hub/conf/conf.env" "$ROOT_DIR/beaut" jobs |
      jq -e --arg id "$id" ".[] | select(.id == \$id) | $filter" >/dev/null 2>&1; then
      return 0
    fi
    pause 0.2
  done
  printf 'smoke: timeout waiting for job %s: %s\n' "$id" "$what" >&2
  return 1
}

rm -rf -- "$BUILD"
mkdir -p "$BUILD/hub/conf" "$BUILD/w1/conf" "$BUILD/w2/conf" \
  "$BUILD/projects/http"
render_node "$BUILD/hub/conf/conf.env" hub "$BUILD/hub" "$W1_PORT"
render_node "$BUILD/w1/conf/conf.env" worker "$BUILD/w1" "$W1_PORT"
render_node "$BUILD/w2/conf/conf.env" worker "$BUILD/w2" "$W2_PORT"

# The HTTP fixture declares its published port at run time so the test can use
# a free port instead of committing one to the repository.
cp "$ROOT_DIR/containers/http/Dockerfile" "$BUILD/projects/http/Dockerfile"
cp "$ROOT_DIR/containers/http/index.html" "$BUILD/projects/http/index.html"
printf 'RUN_MODE=service\nPORTS=%s:8000\n' "$APP_PORT" \
  >"$BUILD/projects/http/beaut.env"

BEAUT_CONFIG="$BUILD/hub/conf/conf.env" "$ROOT_DIR/bin/beaut-hub" >"$BUILD/hub.log" 2>&1 &
HUB_PID=$!
BEAUT_CONFIG="$BUILD/hub/conf/conf.env" "$ROOT_DIR/bin/beaut-work" >"$BUILD/work.log" 2>&1 &
WORK_PID=$!
wait_http "http://$TEST_ADDRESS:$HUB_PORT/health"
wait_http "http://$TEST_ADDRESS:$WORK_PORT/health"

BEAUT_CONFIG="$BUILD/w1/conf/conf.env" "$ROOT_DIR/bin/beaut-worker" >"$BUILD/w1.log" 2>&1 &
W1_PID=$!
wait_workers 1
wait_http "http://$TEST_ADDRESS:$W1_PORT/health"

BEAUT_CONFIG="$BUILD/w2/conf/conf.env" "$ROOT_DIR/bin/beaut-worker" >"$BUILD/w2.log" 2>&1 &
W2_PID=$!
wait_workers 2
wait_http "http://$TEST_ADDRESS:$W2_PORT/health"

status="$(hub_status)"
jq -e '(.workers | length) == 2' <<<"$status" >/dev/null
jq -e '[.workers[].hash] | (length == 2 and .[0] != .[1])' <<<"$status" >/dev/null
jq -e 'all(.workers[]; (.hash | test("^[0-9a-f]{16}$")) and .address != "")' \
  <<<"$status" >/dev/null
jq -e 'all(.workers[]; (.resources.cpus > 0) and (.resources.mem_total_kb > 0))' \
  <<<"$status" >/dev/null
[[ "$(curl -fsS --noproxy '*' "http://$TEST_ADDRESS:$HUB_PORT/")" == *"$TEST_ADDRESS"* ]]
[[ "$(curl -fsS --noproxy '*' "http://$TEST_ADDRESS:$WORK_PORT/work?hash=zzzz")" == ":" ]]

hello_id="$(BEAUT_CONFIG="$BUILD/hub/conf/conf.env" "$ROOT_DIR/beaut" run "$ROOT_DIR/containers/hello")"
JOB_IDS+=("$hello_id")
wait_job "$hello_id" '.state == "done"' "one-shot job done"

http_id="$(BEAUT_CONFIG="$BUILD/hub/conf/conf.env" "$ROOT_DIR/beaut" run "$BUILD/projects/http")"
JOB_IDS+=("$http_id")
wait_job "$http_id" '.state == "running" and .primary != null and .backup != null' \
  "HTTP job running with a backup"
wait_http "http://$TEST_ADDRESS:$APP_PORT/"
[[ "$(curl -fsS --noproxy '*' "http://$TEST_ADDRESS:$APP_PORT/")" == "beaut test page" ]]

primary="$(job_field "$http_id" primary)"
backup="$(job_field "$http_id" backup)"
primary_port="$(hub_status | jq -r --arg h "$primary" '.workers[] | select(.hash == $h) | .port')"
backup_port="$(hub_status | jq -r --arg h "$backup" '.workers[] | select(.hash == $h) | .port')"
[[ "$primary_port" == "$W1_PORT" || "$primary_port" == "$W2_PORT" ]]
[[ "$backup_port" == "$W1_PORT" || "$backup_port" == "$W2_PORT" ]]
[[ "$primary_port" != "$backup_port" ]]

if [[ "$backup_port" == "$W1_PORT" ]]; then
  backup_root="$BUILD/w1"
else
  backup_root="$BUILD/w2"
fi

for ((i = 0; i < 100; i++)); do
  snapshot_worker="$(job_field "$http_id" snapshot.worker)"
  [[ "$snapshot_worker" == "$backup" ]] && break
  pause 0.2
done
[[ "$snapshot_worker" == "$backup" ]]
compgen -G "$backup_root/snapshots/incoming/$http_id/*.tar.gz" >/dev/null

# Simulate the primary machine dying. Both test workers share one Docker
# daemon, so the leftover container is removed explicitly.
if [[ "$primary_port" == "$W1_PORT" ]]; then
  kill "$W1_PID" 2>/dev/null || true
  W1_PID=""
else
  kill "$W2_PID" 2>/dev/null || true
  W2_PID=""
fi
"$DOCKER_CMD" rm -f "beaut-$http_id" >/dev/null 2>&1 || true

wait_job "$http_id" ".state == \"running\" and .primary == \"$backup\"" \
  "failover to the backup worker" 200
wait_http "http://$TEST_ADDRESS:$APP_PORT/" 200
[[ "$(curl -fsS --noproxy '*' "http://$TEST_ADDRESS:$APP_PORT/")" == "beaut test page" ]]

BEAUT_CONFIG="$BUILD/hub/conf/conf.env" "$ROOT_DIR/beaut" status >/dev/null
BEAUT_CONFIG="$BUILD/hub/conf/conf.env" "$ROOT_DIR/beaut" status --json |
  jq -e '.workers and .jobs' >/dev/null

printf 'smoke: ok\n'
