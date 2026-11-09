#!/usr/bin/env bash
# svr_test.sh — hidden personal tree: random directory and URL path modes,
# journal layout under the secret prefix, migration and CLI installation.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
. "$TESTS_DIR/lib/assert.sh"
. "$TESTS_DIR/lib/server.sh"

sandbox="$(mktemp -d)"
trap 'server_stop; rm -rf -- "$sandbox"' EXIT

export STATE_DIR="$sandbox/state"
export PUBLISHED_ROOT="$sandbox/shared"
export SERVICE_ROOT="$sandbox/service"
export SVR_DIR_FILE="$sandbox/state/svr_dir"
export SVR_PATH_FILE="$sandbox/state/svr_path"
export LOG_LEVEL='error'
export JOURNAL_GIT='0'
mkdir -p "$STATE_DIR" "$PUBLISHED_ROOT" "$SERVICE_ROOT"

. "$PROJECT_ROOT/site/scripts/lib/core.sh"
. "$PROJECT_ROOT/site/scripts/lib/personal_tree.sh"
. "$PROJECT_ROOT/site/scripts/lib/journal.sh"

# --- random hidden directory + random URL path ------------------------------
unset SVR_DIR SVR_ROOT
export SVR_MODE='random'
random_path="$(personal_tree_initialize)"
random_dir="$(tr -d '[:space:]' < "$SVR_DIR_FILE")"
assert_matches '^[a-z0-9]{8}$' "$random_path" "random URL path shape"
assert_matches '^\.svr-[a-z0-9]{8}$' "$random_dir" "random hidden directory name"
assert_equal "$SERVICE_ROOT/$random_dir" "$(personal_tree_root)" "root uses hidden name"
assert_equal "$random_path" "$(personal_tree_current_path)" "random URL path is stable"
assert_equal "$random_path" "$(personal_tree_current_path)" "random URL path persists"
assert_equal "$random_path" "$(tr -d '[:space:]' < "$SVR_PATH_FILE")" "path file content"
assert_matches '^600$' "$(stat -c '%a' "$SVR_PATH_FILE")" "path file is private"
assert_matches '^600$' "$(stat -c '%a' "$SVR_DIR_FILE")" "directory file is private"
assert_file_exists "$(personal_tree_root)/DEFAULT.sh" "static default script"
assert_file_exists "$(personal_tree_root)/notes" "notes directory"

journal_initialize
assert_file_exists "$(personal_tree_root)/journal" "journal directory"

# --- changing SVR_DIR moves the existing tree -------------------------------
export SVR_DIR='movedhome'
assert_equal "$SERVICE_ROOT/movedhome" "$(personal_tree_root)" "new SVR_DIR is used"
assert_file_exists "$SERVICE_ROOT/movedhome/journal" "tree moved with SVR_DIR"
assert_file_missing "$SERVICE_ROOT/$random_dir" "old directory is gone"
assert_equal 'movedhome' "$(tr -d '[:space:]' < "$SVR_DIR_FILE")" \
  "SVR_DIR_FILE records the move"
unset SVR_DIR
assert_equal "$SERVICE_ROOT/movedhome" "$(personal_tree_root)" \
  "previous directory persists when SVR_DIR is empty"

# --- explicit hidden URL path -----------------------------------------------
export SVR_PATH='pinned01'
assert_equal 'pinned01' "$(personal_tree_current_path)" "SVR_PATH wins"
assert_equal '/pinned01' "$(personal_tree_url_path)" "SVR_PATH URL prefix"
SVR_PATH='bad/path'
assert_failure "SVR_PATH rejects slashes" personal_tree_current_path
unset SVR_PATH

# --- URL prefix modes -------------------------------------------------------
export SVR_MODE='sha'
export SVR_SECRET='a long shared secret'
sha_expected="$(printf '%s' 'beaut-svr:a long shared secret' | sha256sum | awk '{print $1}')"
sha_expected="${sha_expected:0:8}"
assert_equal "$sha_expected" "$(personal_tree_current_path)" "sha mode derives the path"
assert_equal "$sha_expected" "$(personal_tree_current_path)" "sha path is deterministic"
unset SVR_SECRET
assert_failure "sha mode requires SVR_SECRET" personal_tree_current_path

export SVR_MODE='plain'
export SVR='comalamaison'
assert_equal 'comalamaison' "$(personal_tree_current_path)" "plain URL path"
assert_equal '/comalamaison' "$(personal_tree_url_path)" "plain URL prefix"
SVR='bad/path'
assert_failure "plain path rejects slashes" personal_tree_current_path
SVR='..'
assert_failure "plain path rejects dot-dot" personal_tree_current_path

# --- explicit SVR_DIR -------------------------------------------------------
export SVR_DIR='sheethome'
export SVR='hidden01'
assert_equal "$SERVICE_ROOT/sheethome" "$(personal_tree_root)" "explicit SVR_DIR"
assert_equal 'sheethome' "$(personal_tree_directory_name)" "directory name"
unset SVR_DIR SVR_DIR_FILE
export SVR_DIR_FILE="$sandbox/state/svr_dir_2"

# --- legacy migration: svr/ and diary/ --------------------------------------
legacy_service="$sandbox/legacy-service"
mkdir -p "$legacy_service/svr/diary"
printf 'old entry\n' > "$legacy_service/svr/diary/2026-01-01.md"
SERVICE_ROOT="$legacy_service" SVR_DIR='sheethome' SVR_DIR_FILE="$legacy_service/state/svr_dir" \
  personal_tree_initialize >/dev/null
assert_file_exists "$legacy_service/sheethome/journal/2026-01-01.md" \
  "diary is migrated to journal"
assert_file_missing "$legacy_service/svr" "legacy tree is moved"

# --- journal under the secret prefix ---------------------------------------
export SVR_DIR='sheethome'
export SVR_DIR_FILE="$sandbox/state/svr_dir"
export SVR_MODE='plain'
export SVR='hidden01'
export HOST='testhost'
export USER='tester'
export JOURNAL_DATE='2026-01-02'
export JOURNAL_TIME='09:30:00'
personal_tree_initialize >/dev/null
journal_initialize
journal_add 'first entry' >/dev/null

# --- scripts mirrored through the hidden path ------------------------------
mkdir -p "$PUBLISHED_ROOT/scripts"
printf '#!/bin/sh\necho site script\n' > "$PUBLISHED_ROOT/scripts/hello.sh"
ln -sfn "$(personal_tree_root)" "$PUBLISHED_ROOT/oldhidden"
personal_tree_link_site
assert_success "hidden tree is mirrored in the site tree" \
  test -L "$PUBLISHED_ROOT/hidden01"
assert_success "scripts are linked into the hidden tree" \
  test -L "$(personal_tree_root)/scripts"
assert_file_missing "$PUBLISHED_ROOT/oldhidden" "stale mirrors are removed"

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

# --- CLI --------------------------------------------------------------------
cli_path="$(cd "$PROJECT_ROOT" && SVR_MODE=plain SVR=hidden01 bash scripts/svr.sh path)"
assert_equal '/hidden01' "$cli_path" "svr.sh path"

cli_service="$sandbox/cli-service"
cli_init="$(cd "$PROJECT_ROOT" && SERVICE_ROOT="$cli_service" \
  SVR_MODE=plain SVR=hidden01 SVR_DIR=sheethome JOURNAL_GIT=0 \
  bash scripts/svr.sh init)"
assert_contains "$cli_init" 'personal tree: /hidden01' "svr.sh init"
assert_contains "$cli_init" 'journal:' "svr.sh init reports the journal root"
assert_file_exists "$cli_service/sheethome/journal" "svr.sh init creates the journal"

cli_bin="$sandbox/cli-bin"
(cd "$PROJECT_ROOT" && SVR_BIN_DIR="$cli_bin" bash scripts/svr.sh install "$cli_bin") >/dev/null
assert_file_exists "$cli_bin/journal" "svr install puts journal in PATH"
assert_file_exists "$cli_bin/journal-perso" "svr install puts journal-perso in PATH"
