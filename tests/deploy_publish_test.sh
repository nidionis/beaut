#!/usr/bin/env bash
# deploy_publish_test.sh — /node is rendered on the server from the uploaded
# script, and privileged/device/personal-tree steps stay wired into deploy.sh.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
. "$TESTS_DIR/lib/assert.sh"

sandbox="$(mktemp -d)"
trap 'rm -rf -- "$sandbox"' EXIT

# --- published artifact -----------------------------------------------------
artifact="$sandbox/node.sh"
bash "$PROJECT_ROOT/scripts/build_published_node.sh" 'beaut.example' 9090 > "$artifact"
source_text="$(cat "$artifact")"
assert_contains "$source_text" '#!/bin/sh' "POSIX shebang"
assert_contains "$source_text" "SERVER_HOST='beaut.example'" "server host is baked in"
assert_contains "$source_text" "HTTP_PORT='9090'" "http port is baked in"
assert_not_contains "$source_text" 'BASH_SOURCE' "no BASH_SOURCE dependency"
assert_not_contains "$source_text" 'source ' "no sourced files"
assert_success "artifact parses" bash -n "$artifact"
if command -v dash >/dev/null 2>&1; then
  assert_success "artifact parses as POSIX sh" dash -n "$artifact"
fi

# --- deploy orchestration ---------------------------------------------------
deploy_text="$(cat "$PROJECT_ROOT/deploy.sh")"
assert_contains "$deploy_text" "build_published_node.sh '\$SERVER_HOST' '\$HTTP_PORT'" \
  "/node is built on the server"
assert_not_contains "$deploy_text" 'beaut-node.XXXXXX' "no local node artifact"
assert_not_contains "$deploy_text" 'copy_to_service_user "$published_node_artifact"' \
  "the node artifact is not uploaded"
assert_contains "$deploy_text" 'install_privileged.sh' "privileged scripts are refreshed"
assert_contains "$deploy_text" 'device.sh init' "device identity is initialized"
assert_contains "$deploy_text" 'svr.sh init' "personal tree is initialized"
assert_contains "$deploy_text" 'sync-peers' "approved peers are synchronized"
assert_contains "$deploy_text" 'service_user_is_ready' "existing identity is auto-detected"

# --- configuration order ----------------------------------------------------
install_text="$(cat "$PROJECT_ROOT/deploy/files/install_privileged.sh")"
override_line="$(printf '%s\n' "$install_text" | grep -n 'SERVICE_ROOT=%s' | cut -d: -f1)"
schema_line="$(printf '%s\n' "$install_text" | grep -n 'config.env.example" >>' | cut -d: -f1)"
assert_true_order="$(printf '%s\n' "$override_line $schema_line" | awk '{print ($1<$2)?"yes":"no"}')"
assert_equal 'yes' "$assert_true_order" "root overrides are written before the schema"

bootstrap_text="$(cat "$PROJECT_ROOT/deploy/files/bootstrap.sh")"
bootstrap_override_line="$(printf '%s\n' "$bootstrap_text" | grep -n 'SERVICE_ROOT=%s' | cut -d: -f1)"
bootstrap_schema_line="$(printf '%s\n' "$bootstrap_text" | grep -n 'config.env.example" >>' | cut -d: -f1)"
bootstrap_order="$(printf '%s\n' "$bootstrap_override_line $bootstrap_schema_line" | awk '{print ($1<$2)?"yes":"no"}')"
assert_equal 'yes' "$bootstrap_order" "bootstrap overrides are written before the schema"

# --- privileged refresh actually runs --------------------------------------
service_home="$sandbox/service"
root_library="$sandbox/root-library"
mkdir -p "$service_home/.beaut/scripts/lib" "$service_home/.beaut/state" "$service_home/.beaut/shared"
printf '#!/bin/sh\nprintf refreshed\\n\n' > "$service_home/.beaut/scripts/refresh.sh"
printf '#!/bin/sh\n' > "$service_home/.beaut/scripts/lib/helper.sh"
cat > "$service_home/.beaut/config.env.example" <<'SCHEMA'
SERVICE_USER=${SERVICE_USER:-beaut}
STATE_DIR=${STATE_DIR:-$HOME/.beaut/state}
SVR_ROOT=${SVR_ROOT:-$SERVICE_ROOT/svr}
SCHEMA

SERVICE_HOME="$service_home" ROOT_LIBRARY_DIRECTORY="$root_library" \
  bash "$PROJECT_ROOT/deploy/files/install_privileged.sh" >/dev/null 2>&1
assert_file_exists "$root_library/scripts/refresh.sh" "privileged script copy"
assert_file_exists "$root_library/scripts/lib/helper.sh" "privileged library copy"
assert_equal '755' "$(stat -c '%a' "$root_library/scripts/refresh.sh")" "privileged scripts are executable"

root_config="$(cat "$root_library/config.env")"
assert_contains "$root_config" "SERVICE_ROOT=$service_home/.beaut" "root config service root"
assert_contains "$root_config" "STATE_DIR=$service_home/.beaut/state" "root config state"
assert_contains "$root_config" "PUBLISHED_ROOT=$service_home/.beaut/shared" "root config published root"
assert_equal 'SERVICE_ROOT='"$service_home"'/.beaut' "$(printf '%s\n' "$root_config" | head -1)" \
  "root config starts with the path override"
assert_contains "$root_config" 'SVR_ROOT=${SVR_ROOT:-$SERVICE_ROOT/svr}' "schema is appended after overrides"

