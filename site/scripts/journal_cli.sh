#!/usr/bin/env bash
# journal_cli.sh — installed as `journal` and `journal-perso` by `svr install`.
#
# Reference-compatible usage:
#   journal [subfolder] <name>       create/edit one entry and commit it
#   journal-perso [name]             same, in the personal journal
#
# Convenience subcommands:
#   journal list [count]
#   journal show [date] [subfolder] [name]
#   journal sync
#   journal remote [url]
#
# The journal root is a git repository when JOURNAL_GIT=1. Pull happens before
# an edit, commit after it, push when a remote is configured. `remote <url>`
# updates origin, which is how a restored server points at its new address.
set -uo pipefail

JOURNAL_CLI_SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
JOURNAL_CLI_DIR="$(cd "$(dirname "$JOURNAL_CLI_SELF")" && pwd)"

. "$JOURNAL_CLI_DIR/lib/core.sh"
. "$JOURNAL_CLI_DIR/lib/personal_tree.sh"
. "$JOURNAL_CLI_DIR/lib/journal.sh"
load_config

journal_cli_usage() {
  cat >&2 <<'EOF'
usage: journal [subfolder] <name>
       journal list [count]
       journal show [date] [subfolder] [name]
       journal sync
       journal push
       journal remote [url]
EOF
}

journal_perso_usage() {
  cat >&2 <<'EOF'
usage: journal-perso [name]
       journal-perso [subfolder] <name>
       journal-perso list [count]
       journal-perso show [date] [subfolder] [name]
       journal-perso sync
EOF
}

journal_main() {
  case "${1:-}" in
    ''|-h|--help|help)
      journal_cli_usage
      ;;
    list)
      shift
      journal_list "${1:-0}"
      ;;
    show)
      shift
      journal_show "$@"
      ;;
    sync)
      journal_sync "$(journal_root)"
      ;;
    remote)
      shift
      if [[ -n "${1:-}" ]]; then
        remote="$(journal_remote_resolve "$1" "$(journal_root)")" || return 1
        journal_remote_set "$(journal_root)" "$remote" && journal_git_push "$(journal_root)"
      else
        journal_remote_get "$(journal_root)" || printf 'no remote\n' >&2
      fi
      ;;
    add)
      shift
      journal_add "$*"
      ;;
    *)
      journal_open "$@"
      ;;
  esac
}

journal_perso_main() {
  case "${1:-}" in
    ''|-h|--help|help)
      journal_perso_usage
      ;;
    list)
      shift
      journal_list "${1:-0}" "$(journal_perso_root)"
      ;;
    show)
      shift
      JOURNAL_ROOT="$(journal_perso_root)" journal_show "$@"
      ;;
    sync)
      journal_sync "$(journal_perso_root)"
      ;;
    *)
      journal_perso_open "$@"
      ;;
  esac
}

case "$(basename -- "$0")" in
  journal-perso) journal_perso_main "$@" ;;
  *)             journal_main "$@" ;;
esac
