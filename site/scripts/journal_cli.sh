#!/usr/bin/env bash
# journal_cli.sh — installed as `journal` and `journal-perso` by `svr install`.
#
#   journal [subfolder] <name>       create/edit one entry (pull, edit, commit, push)
#   journal list [count]             newest first
#   journal show [date] [subfolder] [name]
#   journal add <text>               non-interactive append
#   journal sync | push | remote [url]
set -uo pipefail

JOURNAL_CLI_SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
JOURNAL_CLI_DIR="$(cd "$(dirname "$JOURNAL_CLI_SELF")" && pwd)"

. "$JOURNAL_CLI_DIR/lib/core.sh"
. "$JOURNAL_CLI_DIR/lib/journal.sh"
load_config

usage() {
  cat >&2 <<'EOF'
usage: journal [subfolder] <name>
       journal list [count]
       journal show [date] [subfolder] [name]
       journal add <text>
       journal sync | push
       journal remote [url]
EOF
  exit 2
}

case "$(basename -- "$0")" in
  journal-perso)
    root="$(journal_perso_root)"
    subfolder="${PERSO_SUBFOLDER:-fouretout}"
    ;;
  *)
    root="$(journal_root)"
    subfolder="${JOURNAL_SUBFOLDER:-notes}"
    ;;
esac

case "${1:-}" in
  ''|-h|--help|help) usage ;;
  list)   journal_list "${2:-0}" "$root" ;;
  show)   JOURNAL_ROOT="$root" journal_show "${@:2}" ;;
  sync)   journal_sync "$root" ;;
  push)   journal_push "$root" ;;
  add)
    shift
    if [[ "$(basename -- "$0")" == "journal-perso" ]]; then
      journal_write_text "$root" "$subfolder" "${JOURNAL_FILE_NAME:-notes}" "$*" "${PERSO_REMOTE:-}"
    else
      journal_write_text "$root" "$subfolder" "${JOURNAL_FILE_NAME:-notes}" "$*"
    fi
    ;;
  remote)
    if [[ -n "${2:-}" ]]; then
      resolved="$(journal_remote_resolve "$2" "$root")" || exit 1
      journal_remote_set "$root" "$resolved" && journal_git_push "$root"
    else
      journal_remote_get "$root" || printf 'no remote\n' >&2
    fi
    ;;
  *)
    if [[ "$(basename -- "$0")" == "journal-perso" ]]; then
      journal_perso_open "$@"
    else
      journal_open "$@"
    fi
    ;;
esac
