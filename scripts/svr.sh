#!/usr/bin/env bash
# svr.sh — hidden personal tree and Markdown journal CLI.
#
# Usage:
#   svr.sh init                    create the tree and persist the hidden path
#   svr.sh path                    print the secret URL prefix
#   svr.sh status                  print mode, path and root
#   svr.sh journal add <text>      append an entry to today's Markdown file
#   svr.sh journal list [count]    list journal files, newest first
#   svr.sh journal show [date]     print one day (YYYY-MM-DD or today)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/core.sh"
. "$SCRIPT_DIR/lib/personal_tree.sh"
. "$SCRIPT_DIR/lib/journal.sh"
load_config

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

command="${1:-}"
[[ -n "$command" ]] || usage
shift

case "$command" in
  init)
    path="$(personal_tree_initialize)" || exit 1
    printf 'personal tree: /%s\nroot: %s\n' "$path" "$(personal_tree_root)"
    ;;
  path)
    personal_tree_url_path || exit 1
    printf '\n'
    ;;
  status)
    printf 'mode: %s\npath: %s\nroot: %s\n' \
      "${SVR_MODE:-random}" "$(personal_tree_url_path)" "$(personal_tree_root)"
    ;;
  journal)
    action="${1:-}"; shift || true
    case "$action" in
      add)
        journal_add "${1:-}"
        printf '\n'
        ;;
      list)
        journal_list "${1:-0}"
        ;;
      show)
        journal_show "${1:-$(journal_date)}"
        ;;
      *)
        usage
        ;;
    esac
    ;;
  *)
    usage
    ;;
esac
