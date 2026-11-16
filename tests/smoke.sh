#!/usr/bin/env bash
# smoke.sh - start a hub and a worker on loopback and check the base contract.
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/beaut-smoke.XXXXXX")"

# shellcheck source=../lib/common.sh
. "$ROOT_DIR/lib/common.sh"
HUB_PORT="$((20000 + ($$ % 20000)))"
WORKER_PORT="$((HUB_PORT + 1))"
HUB_PID=""
WORKER_PID=""

cleanup() {
  [[ -n "$WORKER_PID" ]] && kill "$WORKER_PID" 2>/dev/null || true
  [[ -n "$HUB_PID" ]] && kill "$HUB_PID" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

render_template "$ROOT_DIR/tests/fixtures/smoke.conf" \
  ROOT "$TMP/root" \
  HUB_PORT "$HUB_PORT" \
  WORKER_PORT "$WORKER_PORT" >"$TMP/conf.env"

render_template "$ROOT_DIR/tests/fixtures/node.env" \
  WORKER_PORT "$WORKER_PORT" >"$TMP/node.env"

export BEAUT_CONFIG="$TMP/conf.env" BEAUT_ENV="$TMP/node.env"

"$ROOT_DIR/bin/beaut-worker" >"$TMP/worker.log" 2>&1 &
WORKER_PID=$!
"$ROOT_DIR/bin/beaut-hub" >"$TMP/hub.log" 2>&1 &
HUB_PID=$!

wait_for() {
  local url="$1" i
  for ((i = 0; i < 100; i++)); do
    if curl -fsS --noproxy '*' --max-time 1 "$url" >/dev/null 2>&1; then
      return 0
    fi
    pause 0.1
  done
  printf 'timeout: %s\n' "$url" >&2
  printf '%s\n' "$(<"$TMP/hub.log")" "$(<"$TMP/worker.log")" >&2 || true
  return 1
}

wait_for "http://127.0.0.1:$WORKER_PORT/health"
wait_for "http://127.0.0.1:$HUB_PORT/health"

status="$(curl -fsS --noproxy '*' "http://127.0.0.1:$HUB_PORT/status")"
jq -e '.workers | length == 1' <<<"$status" >/dev/null
jq -e '.workers[0].name == "w1"' <<<"$status" >/dev/null
jq -e '.workers[0].online == true' <<<"$status" >/dev/null
jq -e '.workers[0].cpus > 0' <<<"$status" >/dev/null
jq -e '.workers[0].mem_total_kb > 0' <<<"$status" >/dev/null

page="$(curl -fsS --noproxy '*' "http://127.0.0.1:$HUB_PORT/")"
[[ "$page" == *w1* ]]
curl -fsS --noproxy '*' "http://127.0.0.1:$HUB_PORT/workers" | jq -e 'length == 1' >/dev/null
headers="$(curl -fsSI --noproxy '*' "http://127.0.0.1:$HUB_PORT/health")"
[[ "$headers" == *'200 OK'* ]]
[[ -s "$TMP/root/state/workers.tsv" ]]
[[ "$(<"$TMP/root/state/workers.tsv")" == name$'\t'* ]]

page="$(curl -fsS --noproxy '*' "http://127.0.0.1:$HUB_PORT/hello/world")"
[[ "$page" == *'<h1>Hello, world</h1>'* ]]
[[ "$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' "http://127.0.0.1:$HUB_PORT/hello/world.html")" == 404 ]]
[[ "$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' "http://127.0.0.1:$HUB_PORT/hello/missing")" == 404 ]]
[[ "$(curl -s --noproxy '*' --path-as-is -o /dev/null -w '%{http_code}' "http://127.0.0.1:$HUB_PORT/../conf.env")" == 404 ]]

raw="$("$ROOT_DIR/beaut" resources --raw)"
[[ $'\n'"$raw" == *$'\n'cpus=* ]]
human="$("$ROOT_DIR/beaut" resources)"
[[ $'\n'"$human" == *$'\n'cpu* ]]
table="$("$ROOT_DIR/beaut" status)"
[[ "$table" == *w1* ]]

printf 'smoke: ok\n'
