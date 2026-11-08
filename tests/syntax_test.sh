#!/usr/bin/env bash
# syntax_test.sh — static gate: every shell file parses, the C relay compiles
# syntactically, and the diff has no whitespace errors.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

for file in \
  deploy.sh beaut.sh \
  scripts/*.sh scripts/lib/*.sh \
  deploy/files/*.sh \
  tests/*.sh tests/lib/*.sh
do
  [[ -f "$file" ]] || continue
  bash -n "$file"
done

gcc -fsyntax-only scripts/http_server.c

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git diff --check
fi

# The published node artifact must stay POSIX sh.
temporary_artifact="$(mktemp)"
trap 'rm -f -- "$temporary_artifact"' EXIT
bash scripts/build_published_node.sh 127.0.0.1 8080 > "$temporary_artifact"
bash -n "$temporary_artifact"
if command -v dash >/dev/null 2>&1; then
  dash -n "$temporary_artifact"
fi
