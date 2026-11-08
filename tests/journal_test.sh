#!/usr/bin/env bash
# journal_test.sh — Markdown journal appends, date/time overrides and listing.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
. "$TESTS_DIR/lib/assert.sh"

sandbox="$(mktemp -d)"
trap 'rm -rf -- "$sandbox"' EXIT

export STATE_DIR="$sandbox/state"
export SERVICE_ROOT="$sandbox/service"
export SVR_ROOT="$sandbox/svr"
export JOURNAL_DIRECTORY="$sandbox/svr/diary"
export LOG_LEVEL='error'
mkdir -p "$STATE_DIR"
. "$PROJECT_ROOT/scripts/lib/core.sh"
. "$PROJECT_ROOT/scripts/lib/journal.sh"

export JOURNAL_DATE='2026-05-04'
export JOURNAL_TIME='07:05'
file="$(journal_add 'morning note')"
assert_equal "$JOURNAL_DIRECTORY/2026-05-04.md" "$file" "journal file path"
assert_equal $'# 2026-05-04\n\n- 07:05 morning note' "$(cat "$file")" "markdown layout"

JOURNAL_TIME='08:06' journal_add $'tabs\tand\nlines'
assert_contains "$(cat "$file")" '- 08:06 tabs and lines' "tabs and newlines are flattened"
assert_equal '2' "$(grep -c '^- ' "$file")" "two entries"
assert_equal '1' "$(grep -c '^# ' "$file")" "single header"

# Dates are independent files.
JOURNAL_DATE='2026-05-05' JOURNAL_TIME='09:00' journal_add 'next day' >/dev/null
assert_file_exists "$JOURNAL_DIRECTORY/2026-05-05.md" "second journal file"
assert_not_contains "$(cat "$file")" 'next day' "dates stay isolated"

# Listing is newest first and bounded.
listing="$(journal_list)"
assert_equal $'2026-05-05.md\n2026-05-04.md' "$(printf '%s\n' "$listing" | xargs -n1 basename)" "list order"
assert_equal '2026-05-05.md' "$(journal_list 1 | xargs -n1 basename)" "list limit"

# Show and input validation.
assert_contains "$(journal_show '2026-05-04')" 'morning note' "show content"
assert_failure "missing date" journal_show '2025-01-01'
assert_failure "empty text" journal_add ''
assert_failure "invalid date" journal_file_for_date '2026-5-4'
assert_failure "date traversal" journal_file_for_date '../2026-05-04'
