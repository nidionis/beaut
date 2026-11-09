#!/usr/bin/env bash
# journal_test.sh — reference-compatible journal: date tree, header, host view,
# listing/show, git commits and the installed journal command.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
. "$TESTS_DIR/lib/assert.sh"

sandbox="$(mktemp -d)"
trap 'rm -rf -- "$sandbox"' EXIT

export STATE_DIR="$sandbox/state"
export SERVICE_ROOT="$sandbox/service"
export SVR_DIR='sheethome'
export LOG_LEVEL='error'
export JOURNAL_ROOT="$SERVICE_ROOT/sheethome/journal"
export PERSO_ROOT="$SERVICE_ROOT/sheethome/perso"
export JOURNAL_GIT='0'
export JOURNAL_DATE='2026-05-04'
export JOURNAL_TIME='07:05:00'
export HOST='testhost'
export USER='tester'
mkdir -p "$STATE_DIR"

. "$PROJECT_ROOT/site/scripts/lib/core.sh"
. "$PROJECT_ROOT/site/scripts/lib/personal_tree.sh"
. "$PROJECT_ROOT/site/scripts/lib/journal.sh"

journal_initialize

# --- one entry: date tree, reference header, host view ----------------------
file="$(journal_add 'morning note')"
assert_equal "$JOURNAL_ROOT/2026/05/04/notes/notes.md" "$file" "journal file path"
content="$(cat "$file")"
assert_contains "$content" '260504' "compact date header"
assert_contains "$content" '07:05:00' "time header"
assert_contains "$content" 'tester' "user header"
assert_contains "$content" 'testhost' "host header"
assert_contains "$content" '###############################################' "separator header"
assert_contains "$content" '2026/05/04/notes/notes.md' "path header"
assert_contains "$content" 'morning note' "entry text"
assert_file_exists "$JOURNAL_ROOT/testhost/notes/notes.md" "per-host hard link"

# --- appending keeps a single header ---------------------------------------
journal_add 'second line' >/dev/null
content="$(cat "$file")"
assert_equal '1' "$(grep -c '^###############################################$' "$file")" \
  "header is written once"
assert_contains "$content" 'second line' "second entry"

# --- a named entry and listing ---------------------------------------------
JOURNAL_DATE='2026-05-05' JOURNAL_TIME='09:10:00' JOURNAL_TEXT='named entry' \
  journal_open notes memo >/dev/null
named="$JOURNAL_ROOT/2026/05/05/notes/memo.md"
assert_file_exists "$named" "named journal file"
assert_contains "$(cat "$named")" 'named entry' "named entry content"

listing="$(journal_list 0 "$JOURNAL_ROOT")"
assert_equal $'2026/05/05/notes/memo.md\n2026/05/04/notes/notes.md' "$listing" \
  "listing is newest first and excludes the host view"
assert_equal '2026/05/05/notes/memo.md' "$(journal_list 1 "$JOURNAL_ROOT")" \
  "listing limit"

# --- show and validation ----------------------------------------------------
assert_contains "$(journal_show '2026-05-04')" 'morning note' "show by date"
assert_contains "$(journal_show '2026-05-04' notes notes)" 'morning note' \
  "show one entry"
assert_failure "missing date" journal_show '2025-01-01'
assert_failure "empty text" journal_add ''
assert_failure "invalid date" journal_file_for_date '2026-5-4'
assert_failure "date traversal" journal_file_for_date '../2026-05-04'
assert_failure "subfolder traversal" journal_relative_path '../notes' 'x'
assert_failure "name traversal" journal_relative_path 'notes' '..'
assert_failure "impossible month" journal_file_for_date '2026-13-04'

# --- git-backed journal and remote -----------------------------------------
if command -v git >/dev/null 2>&1; then
  git_journal="$sandbox/git-journal"
  git_origin="$sandbox/origin.git"
  git init -q --bare "$git_origin"
  JOURNAL_ROOT="$git_journal" JOURNAL_GIT='1' JOURNAL_REMOTE="$git_origin" \
    JOURNAL_DATE='2026-06-01' JOURNAL_TIME='10:00:00' \
    journal_initialize >/dev/null
  JOURNAL_ROOT="$git_journal" JOURNAL_GIT='1' \
    JOURNAL_DATE='2026-06-01' JOURNAL_TIME='10:00:00' \
    journal_add 'committed entry' >/dev/null
  assert_equal "$git_origin" \
    "$(git -C "$git_journal" remote get-url origin)" "journal remote is configured"
  assert_contains "$(git -C "$git_journal" log -1 --format=%s)" \
    'journal: 2026/06/01/notes/notes.md' "journal entry is committed"
  git_branch="$(git -C "$git_journal" rev-parse --abbrev-ref HEAD)"
  assert_equal 'committed entry' \
    "$(git -C "$git_origin" show "$git_branch:2026/06/01/notes/notes.md" | tail -n 1)" \
    "journal entry is pushed"

  # `remote <url>` is the crash-recovery path: it rewrites origin and pushes.
  new_origin="$sandbox/new-origin.git"
  git init -q --bare "$new_origin"
  journal_remote_set "$git_journal" "$new_origin" >/dev/null
  assert_equal "$new_origin" \
    "$(git -C "$git_journal" remote get-url origin)" "remote can be replaced"

  # "hidden" points at the server's hidden journal path.
  resolved="$(JOURNAL_REMOTE_HOST='srv.example' JOURNAL_REMOTE_USER='beaut' \
    JOURNAL_REMOTE_ROOT="$sandbox/service/sheethome" \
    journal_remote_resolve hidden "$git_journal")"
  assert_equal "beaut@srv.example:$sandbox/service/sheethome/git-journal" \
    "$resolved" "hidden remote resolves to the server path"
  assert_equal 'git@example:repo.git' \
    "$(journal_remote_resolve 'git@example:repo.git' "$git_journal")" \
    "plain remote passes through"
else
  printf 'git not found: journal git tests skipped\n'
fi

# --- svr install puts journal commands in the user PATH --------------------
export SVR_BIN_DIR="$sandbox/bin"
bash "$PROJECT_ROOT/site/scripts/svr.sh" install "$SVR_BIN_DIR" >/dev/null
assert_file_exists "$SVR_BIN_DIR/journal" "journal command installed"
assert_file_exists "$SVR_BIN_DIR/journal-perso" "journal-perso command installed"

# The default directory is ~/.local/bin; install adds it to the login shell
# startup file when it is not already on PATH.
fake_home="$sandbox/home"
mkdir -p "$fake_home"
env -u SVR_BIN_DIR HOME="$fake_home" PATH='/usr/bin:/bin' \
  bash "$PROJECT_ROOT/site/scripts/svr.sh" install >/dev/null
assert_file_exists "$fake_home/.local/bin/journal" "default journal command installed"
assert_contains "$(cat "$fake_home/.profile")" 'beaut: journal commands' \
  "login shell PATH is updated"
assert_contains "$(cat "$fake_home/.profile")" '$HOME/.local/bin' \
  "PATH block is relocatable"
env -u SVR_BIN_DIR HOME="$fake_home" PATH='/usr/bin:/bin' \
  bash "$PROJECT_ROOT/site/scripts/svr.sh" install >/dev/null
assert_equal '1' "$(grep -c 'beaut: journal commands' "$fake_home/.profile")" \
  "PATH block is written once"

cli_root="$sandbox/cli-journal"
JOURNAL_ROOT="$cli_root" JOURNAL_GIT='0' JOURNAL_TEXT='from the installed command' \
  JOURNAL_DATE='2026-07-01' JOURNAL_TIME='11:00:00' \
  "$SVR_BIN_DIR/journal" memo >/dev/null
assert_file_exists "$cli_root/2026/07/01/notes/memo.md" \
  "installed journal writes the reference layout"
assert_contains "$(cat "$cli_root/2026/07/01/notes/memo.md")" \
  'from the installed command' "installed journal entry"

# A fresh root is initialized as a git repository on first use.
cli_git_root="$sandbox/cli-git-journal"
JOURNAL_ROOT="$cli_git_root" JOURNAL_GIT='1' JOURNAL_TEXT='git from the command' \
  JOURNAL_DATE='2026-07-02' JOURNAL_TIME='12:00:00' \
  "$SVR_BIN_DIR/journal" memo >/dev/null
assert_file_exists "$cli_git_root/.git/HEAD" "installed journal initializes git"
assert_contains "$(git -C "$cli_git_root" log -1 --format=%s)" \
  'journal: 2026/07/02/notes/memo.md' "installed journal commits"
