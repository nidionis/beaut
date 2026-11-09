#!/usr/bin/env bash
# svr_test.sh — hidden personal tree worktree: name/path, .git file, journal
# under the secret prefix, migration, scripts linking and CLI installation.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
. "$TESTS_DIR/lib/assert.sh"
. "$TESTS_DIR/lib/server.sh"

sandbox="$(mktemp -d)"
trap 'server_stop; rm -rf -- "$sandbox"' EXIT

export STATE_DIR="$sandbox/state"
export PUBLISHED_ROOT="$sandbox/site"
export SERVICE_ROOT="$sandbox/service"
export LOG_LEVEL='error'
export JOURNAL_GIT='0'
mkdir -p "$STATE_DIR" "$PUBLISHED_ROOT" "$SERVICE_ROOT"

. "$PROJECT_ROOT/site/scripts/lib/core.sh"
. "$PROJECT_ROOT/site/scripts/lib/personal_tree.sh"
. "$PROJECT_ROOT/site/scripts/lib/journal.sh"

# --- random hidden name + worktree location ----------------------------------
unset SVR_NAME SVR_PATH SVR_DIR SVR_ROOT SVR_TREE SVR SVR_MODE
random_name="$(personal_tree_initialize)"
assert_matches '^[A-Za-z0-9]{8}$' "$random_name" "random hidden name shape"
assert_equal "$PUBLISHED_ROOT/$random_name" "$(personal_tree_root)" \
  "worktree lives in the published site tree"
assert_equal "$random_name" "$(personal_tree_current_path)" "URL path matches name"
assert_equal "$random_name" "$(personal_tree_current_path)" "name is stable"
assert_file_exists "$(personal_tree_root)/DEFAULT.sh" "static default script"
assert_file_exists "$(personal_tree_root)/notes" "notes directory"

journal_initialize
assert_file_exists "$(personal_tree_root)/journal" "journal directory"

# --- explicit SVR_NAME ------------------------------------------------------
export SVR_NAME='named01'
assert_equal 'named01' "$(personal_tree_name)" "explicit SVR_NAME"
assert_equal "$PUBLISHED_ROOT/named01" "$(personal_tree_root)" "root uses SVR_NAME"
unset SVR_NAME

# --- SVR_PATH overrides URL only (backcompat) --------------------------------
export SVR_PATH='pinned01'
export SVR_NAME='tree01'
assert_equal 'pinned01' "$(personal_tree_current_path)" "SVR_PATH overrides URL"
assert_equal '/pinned01' "$(personal_tree_url_path)" "SVR_PATH URL prefix"
assert_equal "$PUBLISHED_ROOT/tree01" "$(personal_tree_root)" "tree uses SVR_NAME"
unset SVR_PATH SVR_NAME

# --- validation --------------------------------------------------------------
SVR_PATH='bad/path'
assert_failure "SVR_PATH rejects slashes" personal_tree_current_path
unset SVR_PATH
SVR_NAME='bad/name here'
assert_failure "SVR_NAME rejects spaces" personal_tree_name
unset SVR_NAME

# --- legacy plain/SVR mode backcompat ---------------------------------------
export SVR_MODE='plain'
export SVR='hidden01'
assert_equal 'hidden01' "$(personal_tree_current_path)" "plain URL path"
assert_equal '/hidden01' "$(personal_tree_url_path)" "plain URL prefix"
SVR='bad/path'
assert_failure "plain path rejects slashes" personal_tree_current_path
unset SVR SVR_MODE

# --- legacy migration: svr/ and diary/ --------------------------------------
legacy_service="$sandbox/legacy-service"
legacy_site="$sandbox/legacy-site"
mkdir -p "$legacy_service" "$legacy_site" "$legacy_service/svr/diary"
printf 'old entry\n' > "$legacy_service/svr/diary/2026-01-01.md"
SERVICE_ROOT="$legacy_service" PUBLISHED_ROOT="$legacy_site" SVR_NAME='sheethome' \
  JOURNAL_GIT='0' personal_tree_initialize >/dev/null
assert_file_exists "$legacy_site/sheethome/journal/2026-01-01.md" \
  "diary is migrated to journal in the worktree"

# --- journal under the secret prefix ---------------------------------------
export SERVICE_ROOT="$sandbox/service"
export PUBLISHED_ROOT="$sandbox/site"
export SVR_NAME='hidden01'
export SVR_PATH=''
unset SVR SVR_MODE SVR_DIR SVR_ROOT
export HOST='testhost'
export USER='tester'
export JOURNAL_DATE='2026-01-02'
export JOURNAL_TIME='09:30:00'
export JOURNAL_GIT='0'
personal_tree_initialize >/dev/null
journal_initialize
journal_add 'first entry' >/dev/null

# --- scripts mirrored through the hidden path ------------------------------
mkdir -p "$PUBLISHED_ROOT/scripts"
printf '#!/bin/sh\necho site script\n' > "$PUBLISHED_ROOT/scripts/hello.sh"
personal_tree_link_site
assert_success "scripts are linked into the hidden tree" \
  test -L "$(personal_tree_root)/scripts"

server_start "$PUBLISHED_ROOT" "$STATE_DIR"

http_get '/hidden01/scripts/hello.sh'
assert_status 200 "$HTTP_STATUS" "scripts are served under the hidden path"
assert_contains "$HTTP_BODY" 'site script' "hidden script content"
http_get '/scripts/hello.sh'
assert_status 200 "$HTTP_STATUS" "scripts stay public"

http_get "/hidden01/journal/2026/01/02/notes/notes.md"
assert_status 200 "$HTTP_STATUS" "journal is served under the hidden path"
assert_contains "$HTTP_BODY" 'first entry' "served journal content"

http_get '/hidden01/journal/'
assert_status 200 "$HTTP_STATUS" "journal index is served"
assert_equal 'text/html; charset=utf-8' "$HTTP_CONTENT_TYPE" "journal index content type"
assert_contains "$HTTP_BODY" '2026/01/02/notes/notes.md' "journal index links entries"

http_get '/journal'
assert_status 404 "$HTTP_STATUS" "no public journal redirect"
http_get '/journal/'
assert_status 404 "$HTTP_STATUS" "no public journal page"

http_get '/hidden01'
assert_status 200 "$HTTP_STATUS" "tree root resolves to DEFAULT.sh"
assert_contains "$HTTP_BODY" 'beaut personal tree' "static default content"

http_get '/hidden01/notes/missing.md'
assert_status 404 "$HTTP_STATUS" "missing hidden file"

http_get '/wrong01/journal/2026/01/02/notes/notes.md'
assert_status 404 "$HTTP_STATUS" "wrong prefix is not served"

http_get_path_as_is '/hidden01/../etc/passwd'
assert_status 404 "$HTTP_STATUS" "traversal under the hidden path"

# --- worktree with .git file (when git available) ---------------------------
if command -v git >/dev/null 2>&1; then
  wt_service="$sandbox/wt-service"
  wt_site="$sandbox/wt-site"
  mkdir -p "$wt_service" "$wt_site/scripts"
  printf '#!/bin/sh\necho hi\n' > "$wt_site/scripts/s.sh"
  (cd "$PROJECT_ROOT" && SERVICE_ROOT="$wt_service" PUBLISHED_ROOT="$wt_site" \
    SVR_NAME='abc12345' JOURNAL_GIT=1 bash scripts/svr.sh init) >/dev/null
  assert_file_exists "$wt_site/abc12345/.git" "worktree has .git"
  if [[ -f "$wt_site/abc12345/.git" ]]; then
    assert_contains "$(cat "$wt_site/abc12345/.git")" 'gitdir:' \
      "worktree .git is a file pointing to the repo"
  fi
  assert_file_exists "$wt_service/.svr/.git/HEAD" "separate .svr repo exists"
  assert_success "worktree is a valid git checkout" \
    git -C "$wt_site/abc12345" status
fi

# --- CLI --------------------------------------------------------------------
cli_path="$(cd "$PROJECT_ROOT" && SVR_NAME=hidden01 SVR_PATH= bash scripts/svr.sh path)"
assert_equal '/hidden01' "$cli_path" "svr.sh path"

cli_service="$sandbox/cli-service"
cli_site="$sandbox/cli-site"
mkdir -p "$cli_service" "$cli_site"
cli_init="$(cd "$PROJECT_ROOT" && SERVICE_ROOT="$cli_service" PUBLISHED_ROOT="$cli_site" \
  SVR_NAME=hidden01 JOURNAL_GIT=0 bash scripts/svr.sh init)"
assert_contains "$cli_init" 'personal tree: /hidden01' "svr.sh init"
assert_contains "$cli_init" 'journal:' "svr.sh init reports the journal root"
assert_file_exists "$cli_site/hidden01/journal" "svr.sh init creates the journal"

cli_bin="$sandbox/cli-bin"
(cd "$PROJECT_ROOT" && SVR_BIN_DIR="$cli_bin" bash scripts/svr.sh install "$cli_bin") >/dev/null
assert_file_exists "$cli_bin/journal" "svr install puts journal in PATH"
assert_file_exists "$cli_bin/journal-perso" "svr install puts journal-perso in PATH"
