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
bash "$PROJECT_ROOT/site/scripts/build_published_node.sh" 'beaut.example' 9090 > "$artifact"
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
assert_contains "$deploy_text" 'svr.sh install' "journal commands are installed"
assert_contains "$deploy_text" 'sync-peers' "approved peers are synchronized"
assert_contains "$deploy_text" 'service_user_is_ready' "existing identity is auto-detected"
assert_contains "$deploy_text" 'upload_site' "public site tree is uploaded"
assert_contains "$deploy_text" 'sync_site.sh' "site tree is applied on the server"
assert_contains "$deploy_text" "--exclude='.git'" "git repositories are not uploaded as files"
assert_not_contains "$deploy_text" 'shared/' "the published tree is the site tree, not a copy"

remote_install_text="$(cat "$PROJECT_ROOT/site/deploy/remote_install.sh")"
assert_contains "$remote_install_text" 'systemctl --user restart beaut.service' \
  "upgrades restart the running service"
remote_run_line="$(printf '%s\n' "$deploy_text" | grep '^remote_run()')"
assert_contains "$remote_run_line" 'ssh -T' "stdin-fed remote scripts keep stdin open"
assert_not_contains "$remote_run_line" 'ssh -n' "stdin-fed remote scripts do not discard stdin"

# --- tracked public site ----------------------------------------------------
assert_file_exists "$PROJECT_ROOT/site/index.html" "site home is tracked"
assert_file_exists "$PROJECT_ROOT/site/style.css" "site stylesheet is tracked"
assert_file_exists "$PROJECT_ROOT/site/hello/index.html" "site hello page is tracked"
assert_file_missing "$PROJECT_ROOT/site/journal/index.html" "no public journal page is tracked"
assert_file_exists "$PROJECT_ROOT/site/scripts/http_handler.sh" "builtins live in the site tree"
assert_file_exists "$PROJECT_ROOT/site/deploy/sync_site.sh" "site sync script exists"
assert_file_exists "$PROJECT_ROOT/site/scripts/journal_cli.sh" "journal command is tracked"

handler_text="$(cat "$PROJECT_ROOT/site/scripts/http_handler.sh")"
assert_contains "$handler_text" 'index.html' "directories prefer index.html"
assert_contains "$handler_text" 'DEFAU*.sh' "directories fall back to script defaults"
assert_contains "$handler_text" 'path_has_hidden_segment' "dot-prefixed paths stay private"
assert_not_contains "$handler_text" 'journal)' "there is no public journal route"
assert_not_contains "$handler_text" 'http_send_redirect' "no redirect leaks the secret path"

svr_text="$(cat "$PROJECT_ROOT/site/scripts/svr.sh")"
assert_contains "$svr_text" 'install)' "svr install is available"
assert_contains "$svr_text" 'journal-perso' "the personal journal command is wired"
assert_contains "$svr_text" 'journal_remote_set' "git remotes are configurable"
assert_contains "$svr_text" 'personal_tree_link_site' "the hidden tree is mirrored in the site tree"

# --- configuration order ----------------------------------------------------
install_text="$(cat "$PROJECT_ROOT/site/deploy/install_privileged.sh")"
override_line="$(printf '%s\n' "$install_text" | grep -n 'SERVICE_ROOT=%s' | cut -d: -f1)"
schema_line="$(printf '%s\n' "$install_text" | grep -n 'config.env.example" >>' | cut -d: -f1)"
assert_true_order="$(printf '%s\n' "$override_line $schema_line" | awk '{print ($1<$2)?"yes":"no"}')"
assert_equal 'yes' "$assert_true_order" "root overrides are written before the schema"

bootstrap_text="$(cat "$PROJECT_ROOT/site/deploy/bootstrap.sh")"
bootstrap_override_line="$(printf '%s\n' "$bootstrap_text" | grep -n 'SERVICE_ROOT=%s' | cut -d: -f1)"
bootstrap_schema_line="$(printf '%s\n' "$bootstrap_text" | grep -n 'config.env.example" >>' | cut -d: -f1)"
bootstrap_order="$(printf '%s\n' "$bootstrap_override_line $bootstrap_schema_line" | awk '{print ($1<$2)?"yes":"no"}')"
assert_equal 'yes' "$bootstrap_order" "bootstrap overrides are written before the schema"

# --- privileged refresh actually runs --------------------------------------
service_home="$sandbox/service"
root_library="$sandbox/root-library"
mkdir -p "$service_home/.beaut/site/scripts/lib" "$service_home/.beaut/state"
printf '#!/bin/sh\nprintf refreshed\\n\n' > "$service_home/.beaut/site/scripts/refresh.sh"
printf '#!/bin/sh\n' > "$service_home/.beaut/site/scripts/lib/helper.sh"
cat > "$service_home/.beaut/config.env.example" <<'SCHEMA'
SERVICE_USER=${SERVICE_USER:-beaut}
STATE_DIR=${STATE_DIR:-$HOME/.beaut/state}
SVR_DIR=${SVR_DIR:-}
SVR_ROOT=${SVR_ROOT:-}
SCHEMA

SERVICE_HOME="$service_home" ROOT_LIBRARY_DIRECTORY="$root_library" \
  bash "$PROJECT_ROOT/site/deploy/install_privileged.sh" >/dev/null 2>&1
assert_file_exists "$root_library/site/scripts/refresh.sh" "privileged script copy"
assert_file_exists "$root_library/site/scripts/lib/helper.sh" "privileged library copy"
assert_equal '755' "$(stat -c '%a' "$root_library/site/scripts/refresh.sh")" "privileged scripts are executable"

root_config="$(cat "$root_library/config.env")"
assert_contains "$root_config" "SERVICE_ROOT=$service_home/.beaut" "root config service root"
assert_contains "$root_config" "STATE_DIR=$service_home/.beaut/state" "root config state"
assert_contains "$root_config" "PUBLISHED_ROOT=$service_home/.beaut/site" "root config published root"
assert_equal 'SERVICE_ROOT='"$service_home"'/.beaut' "$(printf '%s\n' "$root_config" | head -1)" \
  "root config starts with the path override"
assert_contains "$root_config" 'SVR_DIR=${SVR_DIR:-}' "schema is appended after overrides"

