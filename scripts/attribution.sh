#!/usr/bin/env bash
# attribution.sh — manage virtual secret/path attributions.
#
# Usage:
#   attribution.sh create <kind> <name> <resource> [word_count]
#   attribution.sh ensure <kind> <name> <resource> [word_count]
#   attribution.sh resolve <virtual_path>
#   attribution.sh find <virtual_path>
#   attribution.sh rotate <virtual_path>
#   attribution.sh remove <virtual_path>
#   attribution.sh list
#
# create/ensure/rotate print "virtual_path<TAB>secret". The virtual path is
# never created on disk; only the registry (state) holds the mapping.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/core.sh"
. "$SCRIPT_DIR/lib/virtual_path.sh"
load_config

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

command="${1:-}"
[[ -n "$command" ]] || usage
shift

case "$command" in
  create)  attribution_create "$@" ;;
  ensure)  attribution_ensure "$@" ;;
  resolve) attribution_resolve "$@" ;;
  find)    attribution_find_row "$@" ;;
  rotate)  attribution_rotate "$@" ;;
  remove)  attribution_remove "$@" && printf 'removed %s\n' "$1" ;;
  list)    attribution_list ;;
  *)       usage ;;
esac
