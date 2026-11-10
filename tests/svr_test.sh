#!/usr/bin/env bash
# svr_test.sh — personal tree: SVR_NAME symlink, journal under /$SVR_NAME/,
# scripts linking, git repository and CLI installation.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
. "$TESTS_DIR/lib/assert.sh"
. "$TESTS_DIR/lib/server.sh"

sandbox="$(mktemp -d)"
trap 'server_stop; rm -rf -- "$sandbox"' EXIT

export HOME="$sandbox/home"
export STATE_DIR="$sandbox/state"
export PUBLISHED_ROOT="$sandbox/site"
export SERVICE_ROOT="$sandbox/service"
export LOG_LEVEL='error'
export JOURNAL_GIT='0'
mkdir -p "$HOME" "$STATE_DIR" "$PUBLISHED_ROOT" "$SERVICE_ROOT"

. "$PROJECT_ROOT/site/scripts/lib/core.sh"
. "$PROJECT_ROOT/site/scripts/lib/personal_tree.sh"
. "$PROJECT_ROOT/site/scripts/lib/journal.sh"

# --- random name + symlink layout -------------------------------------------
unset SVR_NAME SVR_ROOT
random_name="$(personal_tree_initialize)"
assert_matches '^[A-Za-z0-9]{8}$' "$random_name" "random name shape"
assert_equal "$HOME/.svr" "$(personal_tree_root)" "SVR_ROOT default"
assert_success "site name is a symlink to SVR_ROOT" test -L "$PUBLISHED_ROOT/$random_name"
assert_equal "$(realpath -m "$HOME/.svr")" "$(realpath -m "$PUBLISHED_ROOT/$random_name")" \
  "symlink target is SVR_ROOT"
assert_equal "$random_name" "$(personal_tree_name)" "name is stable"
assert_file_exists "$(personal_tree_root)/DEFAULT.sh" "static default script"
assert_file_exists "$(personal_tree_root)/notes" "notes directory"

# journal is independent (~/journal by default), not owned by svr

# --- explicit SVR_NAME and SVR_ROOT -----------------------------------------
export SVR_NAME='named01'
export SVR_ROOT="$SERVICE_ROOT/custom-svr"
assert_equal 'named01' "$(personal_tree_name)" "explicit SVR_NAME"
assert_equal "$SERVICE_ROOT/custom-svr" "$(personal_tree_root)" "explicit SVR_ROOT"
unset SVR_NAME SVR_ROOT

# --- an existing checkout is never seeded -----------------------------------
existing_root="$sandbox/existing"
mkdir -p "$existing_root"
printf 'keep\n' > "$existing_root/keep.txt"
SVR_ROOT="$existing_root" SVR_NAME='existing01' personal_tree_initialize >/dev/null
assert_file_exists "$existing_root/keep.txt" "existing files survive"
assert_file_missing "$existing_root/DEFAULT.sh" "existing tree is not seeded"
assert_file_missing "$existing_root/notes" "existing tree keeps its layout"
unset SVR_ROOT SVR_NAME

# --- validation --------------------------------------------------------------
SVR_NAME='bad/name here'
assert_failure "SVR_NAME rejects spaces" personal_tree_name
unset SVR_NAME

# --- journal under /$SVR_NAME/ ----------------------------------------------
export SERVICE_ROOT="$sandbox/service"
export PUBLISHED_ROOT="$sandbox/site"
export SVR_ROOT="$SERVICE_ROOT/.svr"
export SVR_NAME='hidden01'
export HOST='testhost'
export USER='tester'
export JOURNAL_DATE='2026-01-02'
export JOURNAL_TIME='09:30:00'
export JOURNAL_GIT='0'
export JOURNAL_ROOT="$sandbox/journal"
mkdir -p "$PUBLISHED_ROOT"
personal_tree_initialize "$JOURNAL_ROOT" >/dev/null
journal_initialize
journal_add 'first entry' >/dev/null

# --- scripts linked under SVR_ROOT and visible via /$SVR_NAME/scripts/ ------
mkdir -p "$PUBLISHED_ROOT/scripts"
printf '#!/bin/sh\necho site script\n' > "$PUBLISHED_ROOT/scripts/hello.sh"
personal_tree_link_site
assert_success "scripts are linked inside SVR_ROOT" test -L "$(personal_tree_root)/scripts"
assert_success "SVR_NAME is symlinked in site" test -L "$PUBLISHED_ROOT/hidden01"

server_start "$PUBLISHED_ROOT" "$STATE_DIR"

http_get '/hidden01/scripts/hello.sh'
assert_status 200 "$HTTP_STATUS" "scripts served under /SVR_NAME/scripts/"
assert_contains "$HTTP_BODY" 'site script' "script content"
http_get '/scripts/hello.sh'
assert_status 200 "$HTTP_STATUS" "scripts stay public"

http_get "/hidden01/journal/2026/01/02/notes/notes.md"
assert_status 200 "$HTTP_STATUS" "journal served under /SVR_NAME/"
assert_contains "$HTTP_BODY" 'first entry' "journal content"

http_get '/hidden01/journal/'
assert_status 200 "$HTTP_STATUS" "journal index served"
assert_equal 'text/html; charset=utf-8' "$HTTP_CONTENT_TYPE" "journal index content type"
assert_contains "$HTTP_BODY" '2026/01/02/notes/notes.md' "journal index links entries"

http_get '/journal'
assert_status 404 "$HTTP_STATUS" "no public /journal"
http_get '/hidden01'
assert_status 200 "$HTTP_STATUS" "tree root resolves to DEFAULT.sh"
assert_contains "$HTTP_BODY" 'beaut personal tree' "default content"

http_get '/hidden01/notes/missing.md'
assert_status 404 "$HTTP_STATUS" "missing file"
http_get '/wrong01/journal/2026/01/02/notes/notes.md'
assert_status 404 "$HTTP_STATUS" "wrong name not served"
http_get_path_as_is '/hidden01/../etc/passwd'
assert_status 404 "$HTTP_STATUS" "traversal blocked"

# --- git repo in SVR_ROOT (when git available) ------------------------------
if command -v git >/dev/null 2>&1; then
  g_service="$sandbox/g-service"
  g_site="$sandbox/g-site"
  mkdir -p "$g_service" "$g_site/scripts"
  (cd "$PROJECT_ROOT" && SERVICE_ROOT="$g_service" PUBLISHED_ROOT="$g_site" \
    SVR_NAME='git01' SVR_ROOT="$g_service/.svr" JOURNAL_GIT=1 \
    bash scripts/svr.sh init) >/dev/null
  assert_file_exists "$g_service/.svr/.git/HEAD" "SVR_ROOT is a git repo"
  assert_success "site name symlink exists" test -L "$g_site/git01"
  assert_success "git status works in SVR_ROOT" git -C "$g_service/.svr" status
fi

# --- CLI --------------------------------------------------------------------
cli_path="$(cd "$PROJECT_ROOT" && SVR_NAME=hidden01 bash scripts/svr.sh path)"
assert_equal '/hidden01' "$cli_path" "svr.sh path"

cli_service="$sandbox/cli-service"
cli_site="$sandbox/cli-site"
mkdir -p "$cli_service" "$cli_site"
cli_init="$(cd "$PROJECT_ROOT" && SERVICE_ROOT="$cli_service" PUBLISHED_ROOT="$cli_site" \
  SVR_NAME=hidden01 SVR_ROOT="$cli_service/.svr" JOURNAL_GIT=0 bash scripts/svr.sh init)"
assert_contains "$cli_init" 'personal tree: /hidden01' "svr.sh init"
assert_success "svr.sh init creates site symlink" test -L "$cli_site/hidden01"

cli_bin="$sandbox/cli-bin"
(cd "$PROJECT_ROOT" && SVR_BIN_DIR="$cli_bin" bash scripts/svr.sh install "$cli_bin") >/dev/null
assert_file_exists "$cli_bin/journal" "journal installed"
assert_file_exists "$cli_bin/journal-perso" "journal-perso installed"
