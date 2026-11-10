#!/usr/bin/env bash
# service_test.sh — leases, HTTP claim/heartbeat/release and TCP route sync.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
. "$TESTS_DIR/lib/assert.sh"
. "$TESTS_DIR/lib/server.sh"

sandbox="$(mktemp -d)"
trap '[[ -n "${router_process_pid:-}" ]] && kill "$router_process_pid" 2>/dev/null || true; service_router_stop 2>/dev/null || true; server_stop; rm -rf -- "$sandbox"' EXIT

export STATE_DIR="$sandbox/state"
export PUBLISHED_ROOT="$sandbox/site"
export SVR_ROOT="$sandbox/svr"
export SERVICE_DIRECTORY="$STATE_DIR/services"
export LOG_LEVEL='error'
mkdir -p "$STATE_DIR" "$PUBLISHED_ROOT" "$SVR_ROOT/service/app"

printf '19001 18080\n19002 18081\n' > "$SVR_ROOT/service/app/ports"

. "$PROJECT_ROOT/site/scripts/lib/core.sh"
. "$PROJECT_ROOT/site/scripts/lib/services.sh"

# --- leases ------------------------------------------------------------------
assert_success "valid service port" service_port_valid 8080
assert_failure "port zero is invalid" service_port_valid 0
assert_failure "port above 65535 is invalid" service_port_valid 70000

assert_success "first claim wins" service_claim app worker1
assert_file_exists "$STATE_DIR/services/app/lease.tsv" "lease file"
assert_file_exists "$STATE_DIR/services/app/routes.tsv" "route file"
assert_contains "$(service_status app)" 'worker=worker1' "status shows owner"

assert_failure "second claim is refused while the lease is live" service_claim app worker2
assert_success "owner heartbeat renews" service_heartbeat app worker1
assert_failure "other worker cannot heartbeat" service_heartbeat app worker2

printf 'worker1\t1\n' > "$STATE_DIR/services/app/lease.tsv"
assert_success "expired lease can be claimed by a standby" service_claim app worker2
assert_contains "$(service_status app)" 'worker=worker2' "promotion updates owner"
assert_success "promoted worker releases" service_release app worker2

# --- HTTP lease API ----------------------------------------------------------
server_start "$PUBLISHED_ROOT" "$STATE_DIR"

http_post /service/app/claim 'worker=10.0.0.2'
assert_status 200 "$HTTP_STATUS" "HTTP claim"
assert_contains "$HTTP_BODY" 'claimed: app' "claim response"

http_post /service/app/claim 'worker=10.0.0.3'
assert_status 409 "$HTTP_STATUS" "HTTP claim conflict"

http_post /service/app/heartbeat 'worker=10.0.0.2'
assert_status 200 "$HTTP_STATUS" "HTTP heartbeat"
http_post /service/app/heartbeat 'worker=10.0.0.3'
assert_status 409 "$HTTP_STATUS" "HTTP heartbeat conflict"

http_get /service/app/status
assert_status 200 "$HTTP_STATUS" "HTTP status"
assert_contains "$HTTP_BODY" 'worker=10.0.0.2' "HTTP status owner"

http_get /service/app/run
assert_status 200 "$HTTP_STATUS" "run helper"
assert_contains "$HTTP_BODY" 'service_worker.sh' "run helper fetches the worker"
assert_contains "$HTTP_BODY" "bash -s -- 'app'" "run helper names the service"

http_post /service/app/release 'worker=10.0.0.2'
assert_status 200 "$HTTP_STATUS" "HTTP release"
assert_file_missing "$STATE_DIR/services/app/lease.tsv" "release removes the lease"

http_get /service/missing/run
assert_status 404 "$HTTP_STATUS" "run helper requires a manifest"

server_stop

# --- router targets ----------------------------------------------------------
mkdir -p "$sandbox/bin"
cat > "$sandbox/bin/socat" <<'FAKE_SOCAT'
#!/bin/sh
printf '%s\n' "$*" >> "$SOCAT_LOG"
trap 'exit 0' TERM INT
while :; do sleep 0.2; done
FAKE_SOCAT
chmod 755 "$sandbox/bin/socat"
export PATH="$sandbox/bin:$PATH"
export SOCAT_LOG="$sandbox/socat.log"

assert_success "claim for routing" service_claim app worker3
service_router_sync
assert_file_exists "$SERVICE_DIRECTORY/router/19001.pid" "first listener"
assert_file_exists "$SERVICE_DIRECTORY/router/19002.pid" "second listener"
assert_contains "$(cat "$SOCAT_LOG")" 'TCP-LISTEN:19001,fork,reuseaddr TCP:worker3:18080' "first target"
assert_contains "$(cat "$SOCAT_LOG")" 'TCP-LISTEN:19002,fork,reuseaddr TCP:worker3:18081' "second target"

printf 'worker3\t1\n' > "$SERVICE_DIRECTORY/app/lease.tsv"
assert_success "standby claims the expired lease" service_claim app worker4
service_router_sync
assert_equal 'worker4:18080' "$(cat "$SERVICE_DIRECTORY/router/19001.target")" "promoted target"
assert_contains "$(cat "$SOCAT_LOG")" 'TCP-LISTEN:19001,fork,reuseaddr TCP:worker4:18080' "promoted listener"

assert_success "release for routing" service_release app worker4
service_router_sync
assert_file_missing "$SERVICE_DIRECTORY/router/19001.pid" "first listener removed"
assert_file_missing "$SERVICE_DIRECTORY/router/19002.pid" "second listener removed"

# --- router process ----------------------------------------------------------
process_gone() { ! kill -0 "$1" 2>/dev/null; }
assert_success "claim for router process" service_claim app worker5
export SERVICE_ROUTER_INTERVAL=0.1
bash "$PROJECT_ROOT/site/scripts/tcp_router.sh" > "$sandbox/router.out" 2>&1 &
router_process_pid=$!
for _ in {1..50}; do
  [[ -f "$SERVICE_DIRECTORY/router/19001.pid" ]] && break
  sleep 0.1
done
assert_file_exists "$SERVICE_DIRECTORY/router/19001.pid" "router process binds"
kill "$router_process_pid"
for _ in {1..50}; do
  kill -0 "$router_process_pid" 2>/dev/null || break
  sleep 0.1
done
assert_success "router process exits on TERM" process_gone "$router_process_pid"
assert_file_missing "$SERVICE_DIRECTORY/router/19001.pid" "router process removes listeners"
wait "$router_process_pid" 2>/dev/null || true
router_process_pid=''
assert_success "release for router process" service_release app worker5
