#!/usr/bin/env bash
# run.sh — run the beaut test suite. No root, no external network.
#
# Usage:
#   tests/run.sh                 all tests
#   tests/run.sh --verbose       show logs for passing tests too
#   tests/run.sh --filter NAME   run tests whose file name contains NAME
#   tests/run.sh --list          list test files
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
LOGS_DIRECTORY="$TESTS_DIR/.build/logs"

verbose=0
filter=""
list_only=0
while (( $# > 0 )); do
  case "$1" in
    --verbose|-v) verbose=1 ;;
    --filter)     filter="${2:-}"; shift ;;
    --list)       list_only=1 ;;
    --help|-h)
      sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done

for command in bash curl gcc mktemp; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$command" >&2
    exit 2
  }
done

test_files=()
for test_file in "$TESTS_DIR"/*_test.sh; do
  [[ -f "$test_file" ]] || continue
  test_name="$(basename "$test_file" .sh)"
  if [[ -n "$filter" && "$test_name" != *"$filter"* ]]; then
    continue
  fi
  test_files+=("$test_file")
done

if (( ${#test_files[@]} == 0 )); then
  printf 'no tests found%s\n' "${filter:+ for filter '$filter'}" >&2
  exit 2
fi

if (( list_only == 1 )); then
  for test_file in "${test_files[@]}"; do
    basename "$test_file"
  done
  exit 0
fi

rm -rf -- "$LOGS_DIRECTORY"
mkdir -p -- "$LOGS_DIRECTORY"

printf 'beaut test suite (%s)\n' "$PROJECT_ROOT"
printf '%.0s-' {1..60}
printf '\n'

passed=0
failed=0
failed_names=()
for test_file in "${test_files[@]}"; do
  test_name="$(basename "$test_file" .sh)"
  log_file="$LOGS_DIRECTORY/$test_name.log"
  printf '%-32s' "$test_name"
  if bash "$test_file" > "$log_file" 2>&1; then
    printf 'PASS\n'
    passed=$((passed + 1))
    if (( verbose == 1 )); then
      sed 's/^/    /' "$log_file"
    fi
  else
    printf 'FAIL\n'
    failed=$((failed + 1))
    failed_names+=("$test_name")
    printf -- '--- %s log ---\n' "$test_name"
    sed 's/^/    /' "$log_file"
    printf -- '--- end %s ---\n' "$test_name"
  fi
done

printf '%.0s-' {1..60}
printf '\n'
printf 'passed: %d  failed: %d  total: %d\n' \
  "$passed" "$failed" "$((passed + failed))"

if (( failed > 0 )); then
  printf 'failed tests:\n'
  for failed_name in "${failed_names[@]}"; do
    printf '  - %s\n' "$failed_name"
  done
  exit 1
fi
