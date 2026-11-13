#!/usr/bin/env bash
# run.sh - end-to-end integration tests for beaut.
#
# The suite uses a fake Docker CLI, so it does not need a Docker daemon.
# Everything runs in a temporary directory; no host state is modified.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEP="${BEAUT_TEST_KEEP:-0}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/beaut-tests.XXXXXX")" || exit 1
PIDS=()
PASS=0
FAIL=0

log() { printf '%s\n' "$*"; }
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

port_free() {
  local port="$1"
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    return 1
  fi
  return 0
}

wait_tcp() {
  local host="$1" port="$2" i
  for i in $(seq 1 100); do
    if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

wait_http() {
  local url="$1" i
  for i in $(seq 1 100); do
    curl -fsS --max-time 1 "$url" >/dev/null 2>&1 && return 0
    sleep 0.05
  done
  return 1
}

assert_equal() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$expected" == "$actual" ]]; then ok "$label"; else bad "$label (expected '$expected', got '$actual')"; fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then ok "$label"; else bad "$label (missing '$needle' in '$haystack')"; fi
}

assert_json() {
  local json="$1" filter="$2" label="$3"
  if jq -e "$filter" >/dev/null 2>&1 <<<"$json"; then ok "$label"; else bad "$label (jq filter failed: $filter; json: $json)"; fi
}

cleanup() {
  BEAUT_CONFIG="$TEST_ROOT/hub.conf" "$ROOT/beaut.sh" router stop >/dev/null 2>&1 || true
  local pid
  for pid in "${PIDS[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" >/dev/null 2>&1 || true
  done
  sleep 0.2
  for pid in "${PIDS[@]:-}"; do
    [[ -n "$pid" ]] && kill -9 "$pid" >/dev/null 2>&1 || true
  done
  if (( FAIL == 0 )) && [[ "$KEEP" != "1" ]]; then
    rm -rf -- "$TEST_ROOT"
  else
    log "test artifacts kept in $TEST_ROOT"
  fi
}
trap cleanup EXIT

# Pick a free port range.  The high ports are used for hub, workers, the
# test upstream, and the TCP router; fake Docker containers use base+10/+20.
BASE=""
for _ in $(seq 1 100); do
  candidate=$((20000 + (RANDOM % 20000)))
  free=1
  for offset in $(seq 0 30); do
    if ! port_free $((candidate + offset)); then free=0; break; fi
  done
  if (( free == 1 )); then BASE="$candidate"; break; fi
done
[[ -n "$BASE" ]] || { printf 'cannot find a free test port range\n' >&2; exit 1; }

HUB_PORT=$BASE
W1_PORT=$((BASE + 1))
W2_PORT=$((BASE + 2))
UPSTREAM_PORT=$((BASE + 3))
TCP_PORT=$((BASE + 4))
FAKE1_BASE=$((BASE + 10))
FAKE2_BASE=$((BASE + 20))

chmod +x "$ROOT/tests/fake-docker.sh" "$ROOT/tests/upstream.sh"

cat > "$TEST_ROOT/hub.conf" <<EOF
BEAUT_ROOT="$ROOT"
BEAUT_STATE_DIR="$TEST_ROOT/hub-state"
BEAUT_STORE_DIR="$TEST_ROOT/hub-store"
BEAUT_LOG_DIR="$TEST_ROOT/hub-logs"
BEAUT_WWW_DIR="$ROOT/www"
BEAUT_HUB_NAME="hubtest"
BEAUT_HUB_BIND="127.0.0.1"
BEAUT_HUB_PORT="$HUB_PORT"
BEAUT_HUB_URL="http://127.0.0.1:$HUB_PORT"
BEAUT_PUBLIC_URL="http://127.0.0.1:$HUB_PORT"
BEAUT_HUB_DOMAIN="localhost"
BEAUT_MIN_COPIES="2"
BEAUT_STRICT_COPIES="1"
BEAUT_REPLICA_TIMEOUT="20"
BEAUT_PROXY_TIMEOUT="20"
BEAUT_SESSION_SNAPSHOT_ON_STOP="1"
BEAUT_WORKERS=("w1|127.0.0.1|$W1_PORT|hubtest|100" "w2|127.0.0.1|$W2_PORT|hubtest|90")
BEAUT_ROUTES=()
EOF

cat > "$TEST_ROOT/w1.conf" <<EOF
BEAUT_ROOT="$ROOT"
BEAUT_STATE_DIR="$TEST_ROOT/w1-state"
BEAUT_STORE_DIR="$TEST_ROOT/w1-store"
BEAUT_LOG_DIR="$TEST_ROOT/w1-logs"
BEAUT_HUB_NAME="hubtest"
BEAUT_HUB_URL="http://127.0.0.1:$HUB_PORT"
BEAUT_PUBLIC_URL="http://127.0.0.1:$HUB_PORT"
BEAUT_WORKER_NAME="w1"
BEAUT_NODE_NAME="w1"
BEAUT_WORKER_BIND="127.0.0.1"
BEAUT_WORKER_PORT="$W1_PORT"
BEAUT_WORKER_ADVERTISE="127.0.0.1"
BEAUT_DOCKER="$ROOT/tests/fake-docker.sh"
BEAUT_MIN_COPIES="2"
BEAUT_STRICT_COPIES="1"
BEAUT_REPLICA_TIMEOUT="20"
BEAUT_WORKERS=()
BEAUT_ROUTES=()
EOF

cat > "$TEST_ROOT/w2.conf" <<EOF
BEAUT_ROOT="$ROOT"
BEAUT_STATE_DIR="$TEST_ROOT/w2-state"
BEAUT_STORE_DIR="$TEST_ROOT/w2-store"
BEAUT_LOG_DIR="$TEST_ROOT/w2-logs"
BEAUT_HUB_NAME="hubtest"
BEAUT_HUB_URL="http://127.0.0.1:$HUB_PORT"
BEAUT_PUBLIC_URL="http://127.0.0.1:$HUB_PORT"
BEAUT_WORKER_NAME="w2"
BEAUT_NODE_NAME="w2"
BEAUT_WORKER_BIND="127.0.0.1"
BEAUT_WORKER_PORT="$W2_PORT"
BEAUT_WORKER_ADVERTISE="127.0.0.1"
BEAUT_DOCKER="$ROOT/tests/fake-docker.sh"
BEAUT_MIN_COPIES="2"
BEAUT_STRICT_COPIES="1"
BEAUT_REPLICA_TIMEOUT="20"
BEAUT_WORKERS=()
BEAUT_ROUTES=()
EOF

# ---- deployment target detection -------------------------------------------
DEPLOY_LOCAL="$(
  BEAUT_ROOT="$ROOT" BEAUT_CONFIG="$TEST_ROOT/hub.conf" bash -c '
    . "$BEAUT_ROOT/lib/common.sh"
    . "$BEAUT_ROOT/lib/config.sh"
    . "$BEAUT_ROOT/lib/deploy.sh"
    beaut_load_config
    for host in "$@"; do
      [[ -n "$host" ]] || continue
      deploy_host_is_local "$host" && printf "%s\n" "$host"
    done
  ' _ 127.0.0.1 localhost 192.0.2.1 "$(hostname -I 2>/dev/null | awk '{print $1}')"
)"
assert_contains "$DEPLOY_LOCAL" "127.0.0.1" "deployment detects loopback as local"
assert_contains "$DEPLOY_LOCAL" "localhost" "deployment detects localhost as local"
if [[ "$DEPLOY_LOCAL" == *"192.0.2.1"* ]]; then
  bad "deployment leaves remote addresses remote"
else
  ok "deployment leaves remote addresses remote"
fi

log "beaut integration tests"
log "root: $TEST_ROOT"
log "hub: 127.0.0.1:$HUB_PORT  workers: $W1_PORT $W2_PORT"

BEAUT_CONFIG="$TEST_ROOT/hub.conf" "$ROOT/beaut.sh" hub serve >"$TEST_ROOT/hub.log" 2>&1 &
PIDS+=("$!")
FAKE_DOCKER_STATE="$TEST_ROOT/fake-w1" FAKE_DOCKER_PORT_BASE="$FAKE1_BASE" \
  BEAUT_CONFIG="$TEST_ROOT/w1.conf" "$ROOT/beaut.sh" worker serve >"$TEST_ROOT/w1.log" 2>&1 &
PIDS+=("$!")
FAKE_DOCKER_STATE="$TEST_ROOT/fake-w2" FAKE_DOCKER_PORT_BASE="$FAKE2_BASE" \
  BEAUT_CONFIG="$TEST_ROOT/w2.conf" "$ROOT/beaut.sh" worker serve >"$TEST_ROOT/w2.log" 2>&1 &
PIDS+=("$!")

wait_http "http://127.0.0.1:$HUB_PORT/health" || { bad "hub did not start"; exit 1; }
wait_http "http://127.0.0.1:$W1_PORT/health" || bad "worker w1 did not start"
wait_http "http://127.0.0.1:$W2_PORT/health" || bad "worker w2 did not start"

assert_equal "ok" "$(curl -fsS "http://127.0.0.1:$HUB_PORT/health" 2>/dev/null)" "hub health"
assert_json "$(curl -fsS "http://127.0.0.1:$HUB_PORT/info" 2>/dev/null)" '.role == "hub" and .name == "hubtest"' "hub info"
assert_json "$(curl -fsS "http://127.0.0.1:$HUB_PORT/workers" 2>/dev/null)" \
  'map(select(.name == "w1" and .online == true)) | length == 1' "worker w1 online"
assert_json "$(curl -fsS "http://127.0.0.1:$HUB_PORT/workers" 2>/dev/null)" \
  'map(select(.name == "w2" and .online == true)) | length == 1' "worker w2 online"

# ---- packages ---------------------------------------------------------------
head -c $((2 * 1024 * 1024 + 123)) /dev/urandom > "$TEST_ROOT/blob.bin"
HTTP_CODE="$(curl -sS -o "$TEST_ROOT/upload.json" -w '%{http_code}' \
  -X PUT "http://127.0.0.1:$HUB_PORT/packages?name=blob.bin&kind=data&copies=2" \
  -H 'Content-Type: application/octet-stream' --data-binary @"$TEST_ROOT/blob.bin" 2>/dev/null)"
assert_equal "201" "$HTTP_CODE" "package upload status"
assert_json "$(cat "$TEST_ROOT/upload.json")" '.ok == true and (.manifest.copies | length) == 2 and .manifest.degraded == false' "package replicated to two copies"
PKG_ID="$(jq -r '.manifest.id' "$TEST_ROOT/upload.json")"
assert_contains "$PKG_ID" "sha256:" "package id is content addressed"

curl -fsS "http://127.0.0.1:$HUB_PORT/packages/$PKG_ID/download" -o "$TEST_ROOT/blob.download" || true
if cmp -s "$TEST_ROOT/blob.bin" "$TEST_ROOT/blob.download"; then ok "package download round-trip"; else bad "package download round-trip"; fi

# Lose one hub chunk but keep the worker replica: a download must repair from
# the peer instead of failing or serving a short body.
FIRST_CHUNK="$(jq -r '.manifest.chunks[0]' "$TEST_ROOT/upload.json")"
CHUNK_HEX="${FIRST_CHUNK#sha256:}"
rm -f -- "$TEST_ROOT/hub-store/objects/${CHUNK_HEX:0:2}/$CHUNK_HEX"
curl -fsS "http://127.0.0.1:$HUB_PORT/packages/$PKG_ID/download" -o "$TEST_ROOT/blob.repaired" || true
if cmp -s "$TEST_ROOT/blob.bin" "$TEST_ROOT/blob.repaired"; then
  ok "package download repairs missing chunk from replica"
else
  bad "package download repairs missing chunk from replica"
fi

if curl -fsS "http://127.0.0.1:$W1_PORT/store/packages" 2>/dev/null | jq -e --arg id "$PKG_ID" 'map(select(.id == $id)) | length == 1' >/dev/null; then
  ok "worker w1 stored replica"
else
  bad "worker w1 stored replica"
fi

BUNDLE_CODE="$(curl -sS -o "$TEST_ROOT/bundle.tar.gz" -w '%{http_code}' \
  "http://127.0.0.1:$W1_PORT/store/packages/$PKG_ID/bundle" 2>/dev/null)"
assert_equal "200" "$BUNDLE_CODE" "worker bundle download status"
tar -tzf "$TEST_ROOT/bundle.tar.gz" >"$TEST_ROOT/bundle.list" 2>/dev/null || true
if grep -q 'manifest.json' "$TEST_ROOT/bundle.list"; then
  ok "worker bundle contains manifest"
else
  bad "worker bundle contains manifest"
fi

assert_contains "$(curl -fsS "http://127.0.0.1:$HUB_PORT/" 2>/dev/null)" \
  '<title>beaut</title>' "dashboard served"

if BEAUT_CONFIG="$TEST_ROOT/hub.conf" "$ROOT/beaut.sh" package verify "$PKG_ID" --full >/dev/null 2>&1; then
  ok "CLI package verify --full"
else
  bad "CLI package verify --full"
fi

if BEAUT_CONFIG="$TEST_ROOT/hub.conf" "$ROOT/beaut.sh" package get "$PKG_ID" "$TEST_ROOT/blob.cli" >/dev/null 2>&1 \
   && cmp -s "$TEST_ROOT/blob.bin" "$TEST_ROOT/blob.cli"; then
  ok "CLI package get"
else
  bad "CLI package get"
fi

head -c 2048 /dev/urandom > "$TEST_ROOT/strict.bin"
STRICT_CODE="$(curl -sS -o "$TEST_ROOT/strict.json" -w '%{http_code}' \
  -X PUT "http://127.0.0.1:$HUB_PORT/packages?name=strict.bin&kind=data&copies=9" \
  --data-binary @"$TEST_ROOT/strict.bin" 2>/dev/null)"
assert_equal "503" "$STRICT_CODE" "strict copy enforcement"
assert_json "$(cat "$TEST_ROOT/strict.json")" '.ok == false' "strict copy response marks failure"

# The CLI can explicitly accept a degraded upload through the API.
head -c 512 /dev/urandom > "$TEST_ROOT/degraded.bin"
DEGRADED_MANIFEST="$(BEAUT_CONFIG="$TEST_ROOT/hub.conf" "$ROOT/beaut.sh" package add \
  "$TEST_ROOT/degraded.bin" --copies 9 --allow-degraded 2>/dev/null)" || true
assert_json "$DEGRADED_MANIFEST" '.degraded == true and (.copies | length) >= 2' \
  "CLI package add allow-degraded via API"

# ---- HTTP and TCP routes ----------------------------------------------------
socat "TCP-LISTEN:$UPSTREAM_PORT,bind=127.0.0.1,fork,reuseaddr" \
  "EXEC:$ROOT/tests/upstream.sh" >"$TEST_ROOT/upstream.log" 2>&1 &
PIDS+=("$!")
wait_tcp 127.0.0.1 "$UPSTREAM_PORT" || bad "upstream did not start"

BEAUT_CONFIG="$TEST_ROOT/hub.conf" "$ROOT/beaut.sh" route add app1 app.test / w1 "$UPSTREAM_PORT" http hubtest >/dev/null
assert_contains "$(curl -fsS -H 'Host: app.test' "http://127.0.0.1:$HUB_PORT/hello" 2>/dev/null)" \
  "hello GET /hello" "domain route through hub"
assert_contains "$(curl -fsS -H "Host: app.test:$HUB_PORT" "http://127.0.0.1:$HUB_PORT/hello" 2>/dev/null)" \
  "hello GET /hello" "domain route ignores Host port"
assert_json "$(curl -fsS "http://127.0.0.1:$HUB_PORT/routes" 2>/dev/null)" \
  'map(select(.name == "app1" and .mode == "http")) | length == 1' "route listed by API"

ROUTE_ADD_CODE="$(curl -sS -o "$TEST_ROOT/route-add.json" -w '%{http_code}' \
  -X POST "http://127.0.0.1:$HUB_PORT/routes" -H 'Content-Type: application/json' \
  -d "{\"name\":\"api1\",\"host\":\"api.test\",\"path\":\"/\",\"worker\":\"w1\",\"port\":$UPSTREAM_PORT,\"mode\":\"http\",\"hub\":\"hubtest\"}" 2>/dev/null)"
assert_equal "200" "$ROUTE_ADD_CODE" "route API add status"
assert_json "$(cat "$TEST_ROOT/route-add.json")" \
  'map(select(.name == "api1")) | length == 1' "route API add listed"
assert_contains "$(curl -fsS -H 'Host: api.test' "http://127.0.0.1:$HUB_PORT/api" 2>/dev/null)" \
  "hello GET /api" "route added through API proxies"

ROUTE_DEL_CODE="$(curl -sS -o "$TEST_ROOT/route-del.json" -w '%{http_code}' \
  -X DELETE "http://127.0.0.1:$HUB_PORT/routes/api1" 2>/dev/null)"
assert_equal "200" "$ROUTE_DEL_CODE" "route API delete status"
assert_json "$(curl -fsS "http://127.0.0.1:$HUB_PORT/routes" 2>/dev/null)" \
  'map(select(.name == "api1")) | length == 0' "route API delete removed"

BEAUT_CONFIG="$TEST_ROOT/hub.conf" "$ROOT/beaut.sh" route add tcp1 '*' / w1 "$UPSTREAM_PORT" tcp hubtest "$TCP_PORT" >/dev/null
BEAUT_CONFIG="$TEST_ROOT/hub.conf" "$ROOT/beaut.sh" router sync >/dev/null 2>&1 || true
wait_tcp 127.0.0.1 "$TCP_PORT" || bad "TCP router did not start"
assert_contains "$(curl -fsS "http://127.0.0.1:$TCP_PORT/tcp" 2>/dev/null)" \
  "hello GET /tcp" "raw TCP route through router"

# ---- sessions ---------------------------------------------------------------
CREATE_CODE="$(curl -sS -o "$TEST_ROOT/session.json" -w '%{http_code}' \
  -X POST "http://127.0.0.1:$HUB_PORT/sessions" -H 'Content-Type: application/json' \
  -d '{"name":"itest","image":"alpine:3","container_port":8080,"protocol":"http","worker":"w1"}' 2>/dev/null)"
assert_equal "201" "$CREATE_CODE" "session create status"
assert_json "$(cat "$TEST_ROOT/session.json")" '.ok == true and .session.worker == "w1" and .session.status == "running"' "session created on w1"
SID="$(jq -r '.session.id' "$TEST_ROOT/session.json")"
HPORT="$(jq -r '.session.host_port' "$TEST_ROOT/session.json")"
if [[ "$HPORT" =~ ^[0-9]+$ ]] && (( HPORT > 0 )); then ok "session got host port"; else bad "session got host port ($HPORT)"; fi

socat "TCP-LISTEN:$HPORT,bind=127.0.0.1,fork,reuseaddr" \
  "EXEC:$ROOT/tests/upstream.sh" >"$TEST_ROOT/session-upstream-1.log" 2>&1 &
PIDS+=("$!")
wait_tcp 127.0.0.1 "$HPORT" || bad "session upstream did not start"
assert_contains "$(curl -fsS "http://127.0.0.1:$HUB_PORT/s/$SID/probe" 2>/dev/null)" \
  "hello GET /probe" "session proxy on w1"

SNAP_CODE="$(curl -sS -o "$TEST_ROOT/snapshot.json" -w '%{http_code}' \
  -X POST "http://127.0.0.1:$HUB_PORT/sessions/$SID/snapshot" 2>/dev/null)"
assert_equal "200" "$SNAP_CODE" "session snapshot status"
SNAP_ID="$(jq -r '.snapshot // empty' "$TEST_ROOT/snapshot.json")"
assert_contains "$SNAP_ID" "sha256:" "session snapshot is a content-addressed package"
assert_json "$(curl -fsS "http://127.0.0.1:$HUB_PORT/packages/$SNAP_ID" 2>/dev/null)" \
  '.kind == "session-image"' "snapshot package kind"

RESTORE_CODE="$(curl -sS -o "$TEST_ROOT/restore.json" -w '%{http_code}' \
  -X POST "http://127.0.0.1:$HUB_PORT/sessions/$SID/restore" -H 'Content-Type: application/json' \
  -d '{"worker":"w2"}' 2>/dev/null)"
assert_equal "200" "$RESTORE_CODE" "session restore status"
assert_json "$(cat "$TEST_ROOT/restore.json")" '.ok == true and .session.worker == "w2" and .session.status == "running"' "session moved to w2"
NEWPORT="$(jq -r '.session.host_port' "$TEST_ROOT/restore.json")"
if [[ "$NEWPORT" =~ ^[0-9]+$ ]] && (( NEWPORT > 0 )); then ok "restored session got host port"; else bad "restored session got host port ($NEWPORT)"; fi

socat "TCP-LISTEN:$NEWPORT,bind=127.0.0.1,fork,reuseaddr" \
  "EXEC:$ROOT/tests/upstream.sh" >"$TEST_ROOT/session-upstream-2.log" 2>&1 &
PIDS+=("$!")
wait_tcp 127.0.0.1 "$NEWPORT" || bad "restored session upstream did not start"
assert_contains "$(curl -fsS "http://127.0.0.1:$HUB_PORT/s/$SID/after" 2>/dev/null)" \
  "hello GET /after" "session proxy after restore"
if curl -fsS "http://127.0.0.1:$W1_PORT/sessions" 2>/dev/null \
    | jq -e --arg id "$SID" 'map(select(.id == $id)) | length == 0' >/dev/null; then
  ok "restore removed old worker copy"
else
  bad "restore removed old worker copy"
fi

STOP_CODE="$(curl -sS -o "$TEST_ROOT/stop.json" -w '%{http_code}' \
  -X POST "http://127.0.0.1:$HUB_PORT/sessions/$SID/stop" 2>/dev/null)"
assert_equal "200" "$STOP_CODE" "session stop status"
assert_json "$(cat "$TEST_ROOT/stop.json")" '.ok == true and .session.status == "stopped"' "session stopped"
START_CODE="$(curl -sS -o "$TEST_ROOT/start.json" -w '%{http_code}' \
  -X POST "http://127.0.0.1:$HUB_PORT/sessions/$SID/start" 2>/dev/null)"
assert_equal "200" "$START_CODE" "session start status"
assert_json "$(cat "$TEST_ROOT/start.json")" '.ok == true and .session.status == "running"' "session started again"
assert_contains "$(curl -fsS "http://127.0.0.1:$HUB_PORT/s/$SID/restarted" 2>/dev/null)" \
  "hello GET /restarted" "session proxy after restart"

if BEAUT_CONFIG="$TEST_ROOT/hub.conf" "$ROOT/beaut.sh" session ls --json 2>/dev/null | jq -e --arg id "$SID" 'map(select(.id == $id)) | length == 1' >/dev/null; then
  ok "CLI session ls"
else
  bad "CLI session ls"
fi

# CLI Docker management through the hub API (create/exec/remove).
CLI_SESSION="$(BEAUT_CONFIG="$TEST_ROOT/hub.conf" "$ROOT/beaut.sh" session create clitest alpine:3 \
  --worker w1 --port 8080 --command sleep --command infinity 2>/dev/null)" || true
assert_json "$CLI_SESSION" '.worker == "w1" and .status == "running"' "CLI session create via API"
CLI_SID="$(jq -r '.id // empty' <<<"$CLI_SESSION" 2>/dev/null)"
EXEC_OUT="$(BEAUT_CONFIG="$TEST_ROOT/hub.conf" "$ROOT/beaut.sh" session exec "$CLI_SID" -- echo hello 2>/dev/null)" || true
assert_equal "exec echo hello" "$EXEC_OUT" "CLI session exec via API"
if BEAUT_CONFIG="$TEST_ROOT/hub.conf" "$ROOT/beaut.sh" session rm "$CLI_SID" >/dev/null 2>&1; then
  ok "CLI session rm via API"
else
  bad "CLI session rm via API"
fi

DELETE_CODE="$(curl -sS -o "$TEST_ROOT/delete.json" -w '%{http_code}' \
  -X DELETE "http://127.0.0.1:$HUB_PORT/sessions/$SID" 2>/dev/null)"
assert_equal "200" "$DELETE_CODE" "session delete status"
GONE_CODE="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$HUB_PORT/sessions/$SID" 2>/dev/null)"
assert_equal "404" "$GONE_CODE" "session is gone"

# ---- CLI reports and API-first behaviour ------------------------------------
STATUS_OUT="$(BEAUT_CONFIG="$TEST_ROOT/hub.conf" "$ROOT/beaut.sh" status 2>/dev/null)"
assert_contains "$STATUS_OUT" "health: ok (api)" "CLI status uses hub API"
assert_contains "$STATUS_OUT" "WORKER" "CLI status renders worker table"
WORKERS_OUT="$(BEAUT_CONFIG="$TEST_ROOT/hub.conf" "$ROOT/beaut.sh" workers 2>/dev/null)"
assert_contains "$WORKERS_OUT" "w1" "CLI workers table"
assert_contains "$WORKERS_OUT" "yes" "CLI workers shows online state"
PACKAGES_OUT="$(BEAUT_CONFIG="$TEST_ROOT/hub.conf" "$ROOT/beaut.sh" package ls 2>/dev/null)"
assert_contains "$PACKAGES_OUT" "blob.bin" "CLI package ls via API"
ROUTES_OUT="$(BEAUT_CONFIG="$TEST_ROOT/hub.conf" "$ROOT/beaut.sh" route ls 2>/dev/null)"
assert_contains "$ROUTES_OUT" "app1" "CLI route ls via API"
if BEAUT_CONFIG="$TEST_ROOT/hub.conf" "$ROOT/beaut.sh" route find app.test /hello 2>/dev/null \
   | jq -e '.name == "app1"' >/dev/null; then
  ok "CLI route find via API"
else
  bad "CLI route find via API"
fi
if BEAUT_CONFIG="$TEST_ROOT/hub.conf" "$ROOT/beaut.sh" package scrub --json 2>/dev/null \
   | jq -e '.ok == true and (.results | length) >= 1' >/dev/null; then
  ok "CLI package scrub via API"
else
  bad "CLI package scrub via API"
fi
HELP_OUT="$(BEAUT_CONFIG="$TEST_ROOT/hub.conf" "$ROOT/beaut.sh" --help 2>/dev/null)"
assert_contains "$HELP_OUT" "Installation and node operation" "help covers installation"
assert_contains "$HELP_OUT" "session exec" "help covers Docker management"
API_HELP_OUT="$(BEAUT_CONFIG="$TEST_ROOT/hub.conf" "$ROOT/beaut.sh" help api 2>/dev/null)"
assert_contains "$API_HELP_OUT" "POST /sessions" "help api covers Docker API"

# ---- CLI diagnostics --------------------------------------------------------
if BEAUT_CONFIG="$TEST_ROOT/hub.conf" "$ROOT/beaut.sh" doctor >/dev/null 2>&1; then
  ok "CLI doctor"
else
  bad "CLI doctor"
fi

log ""
log "passed: $PASS  failed: $FAIL"
(( FAIL == 0 )) || exit 1
