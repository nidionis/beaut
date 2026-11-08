#!/usr/bin/env bash
# svr_test.sh — hidden personal-tree path modes, persistence, journal and
# static serving under the secret prefix.
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
export SVR_ROOT="$sandbox/svr"
export SVR_PATH_FILE="$sandbox/state/svr_path"
export JOURNAL_DIRECTORY="$sandbox/svr/diary"
export LOG_LEVEL='error'
mkdir -p "$STATE_DIR" "$PUBLISHED_ROOT" "$SERVICE_ROOT"

. "$PROJECT_ROOT/scripts/lib/core.sh"
. "$PROJECT_ROOT/scripts/lib/personal_tree.sh"
. "$PROJECT_ROOT/scripts/lib/journal.sh"

# --- random mode: shape, persistence, permissions ---------------------------
export SVR_MODE='random'
random_path="$(personal_tree_initialize)"
assert_matches '^[a-z0-9]{8}$' "$random_path" "random hidden path shape"
assert_equal "$random_path" "$(personal_tree_current_path)" "random path is stable"
assert_equal "$random_path" "$(personal_tree_current_path)" "random path persists across calls"
assert_equal "$random_path" "$(tr -d '[:space:]' < "$SVR_PATH_FILE")" "random path is persisted"
assert_matches '^600$' "$(stat -c '%a' "$SVR_PATH_FILE")" "path file is private"
assert_file_exists "$SVR_ROOT/DEFAULT.sh" "static default script"
assert_file_exists "$SVR_ROOT/diary" "journal directory"
assert_file_exists "$SVR_ROOT/notes" "notes directory"

# --- prefix matching --------------------------------------------------------
assert_equal '' "$(personal_tree_match_path "$random_path")" "tree root"
assert_equal 'diary/2026-01-02.md' \
  "$(personal_tree_match_path "$random_path/diary/2026-01-02.md")" "relative path"
assert_failure "wrong prefix does not match" personal_tree_match_path "other/$random_path"

# --- sha mode ---------------------------------------------------------------
export SVR_MODE='sha'
export SVR_SECRET='a long shared secret'
sha_expected="$(printf '%s' 'beaut-svr:a long shared secret' | sha256sum | awk '{print $1}')"
sha_expected="${sha_expected:0:8}"
assert_matches '^[a-z0-9]{8}$' "$sha_expected" "sha digest is short and lowercase"
assert_equal "$sha_expected" "$(personal_tree_current_path)" "sha mode derives the path"
assert_equal "$sha_expected" "$(personal_tree_current_path)" "sha path is deterministic"
unset SVR_SECRET
assert_failure "sha mode requires SVR_SECRET" personal_tree_current_path

# --- plain mode and validation ---------------------------------------------
export SVR_MODE='plain'
export SVR='comalamaison'
assert_equal 'comalamaison' "$(personal_tree_current_path)" "plain path"
assert_equal '/comalamaison' "$(personal_tree_url_path)" "plain URL path"
SVR='bad/path'
assert_failure "plain path rejects slashes" personal_tree_current_path
SVR='..'
assert_failure "plain path rejects dot-dot" personal_tree_current_path
export SVR='hidden01'
export SVR_MODE='plain'

# --- journal ----------------------------------------------------------------
export JOURNAL_DATE='2026-01-02'
export JOURNAL_TIME='09:30'
journal_file="$(journal_add 'first entry')"
assert_file_exists "$journal_file" "journal file"
assert_contains "$(cat "$journal_file")" '# 2026-01-02' "journal date header"
assert_contains "$(cat "$journal_file")" '- 09:30 first entry' "journal entry"

JOURNAL_TIME='10:45' journal_add $'second\nline'
journal_content="$(cat "$journal_file")"
assert_contains "$journal_content" '- 10:45 second line' "newlines are flattened"
assert_equal '1' "$(grep -c '^# 2026-01-02$' "$journal_file")" "header is written once"

JOURNAL_DATE='2026-01-03' journal_add 'next day' >/dev/null
listing="$(journal_list)"
assert_contains "$listing" '2026-01-03.md' "newest journal first"
assert_contains "$listing" '2026-01-02.md' "older journal listed"
assert_equal '2026-01-03.md' "$(journal_list 1 | xargs -n1 basename)" "list limit"
assert_contains "$(journal_show '2026-01-02')" 'first entry' "show by date"
assert_failure "missing journal date" journal_show '2025-12-31'
assert_failure "empty journal entry" journal_add ''
assert_failure "invalid journal date" journal_file_for_date '02-01-2026'

# --- CLI --------------------------------------------------------------------
cli_path="$(cd "$PROJECT_ROOT" && SVR_MODE=plain SVR=hidden01 bash scripts/svr.sh path)"
assert_equal '/hidden01' "$cli_path" "svr.sh path"
cli_init="$(cd "$PROJECT_ROOT" && SVR_MODE=plain SVR=hidden01 bash scripts/svr.sh init)"
assert_contains "$cli_init" 'personal tree: /hidden01' "svr.sh init"

# --- HTTP serving under the secret prefix -----------------------------------
personal_tree_initialize >/dev/null
server_start "$PUBLISHED_ROOT" "$STATE_DIR"

http_get "/hidden01/diary/2026-01-02.md"
assert_status 200 "$HTTP_STATUS" "journal is served under the hidden path"
assert_contains "$HTTP_BODY" 'first entry' "served journal content"

http_get '/hidden01'
assert_status 200 "$HTTP_STATUS" "tree root resolves to DEFAULT.sh"
assert_contains "$HTTP_BODY" 'beaut personal tree' "static default content"

http_get '/hidden01/notes/missing.md'
assert_status 404 "$HTTP_STATUS" "missing hidden file"

http_get '/wrong01/diary/2026-01-02.md'
assert_status 404 "$HTTP_STATUS" "wrong prefix is not served"

http_get_path_as_is '/hidden01/../etc/passwd'
assert_status 404 "$HTTP_STATUS" "traversal under the hidden path"
