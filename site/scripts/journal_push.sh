#!/usr/bin/env bash
# journal_push.sh — push journal and perso to their configured remotes.
# Uses JOURNAL_SSH_PORT / SSH_PORT when resolving "hidden" remotes.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/core.sh"
. "$SCRIPT_DIR/lib/journal.sh"
load_config

usage() {
  cat >&2 <<'EOF'
usage: journal_push.sh [journal|perso|all]
  push  configured journal/perso remotes (uses JOURNAL_SSH_PORT if set)
EOF
  exit 2
}

target="${1:-all}"
case "$target" in
  journal) journal_push "$(journal_root)" ;;
  perso)   journal_push "$(journal_perso_root)" ;;
  all)     journal_push "$(journal_root)"; journal_push "$(journal_perso_root)" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
