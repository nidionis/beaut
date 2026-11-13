#!/usr/bin/env bash
# beaut.sh - thin entry point for the beaut hub/worker fabric.
#
# All command parsing and command implementations live in lib/cli.sh.
set -uo pipefail

if [[ -z "${BEAUT_ROOT:-}" ]]; then
  _beaut_self="${BASH_SOURCE[0]}"
  _beaut_self="$(readlink -f -- "$_beaut_self" 2>/dev/null || printf '%s' "$_beaut_self")"
  BEAUT_ROOT="$(cd "$(dirname "$_beaut_self")" && pwd)"
  unset _beaut_self
fi
export BEAUT_ROOT

. "$BEAUT_ROOT/lib/common.sh"
. "$BEAUT_ROOT/lib/config.sh"
. "$BEAUT_ROOT/lib/api.sh"
. "$BEAUT_ROOT/lib/report.sh"
. "$BEAUT_ROOT/lib/http.sh"
. "$BEAUT_ROOT/lib/store.sh"
. "$BEAUT_ROOT/lib/workers.sh"
. "$BEAUT_ROOT/lib/routes.sh"
. "$BEAUT_ROOT/lib/sessions.sh"
. "$BEAUT_ROOT/lib/docker.sh"
. "$BEAUT_ROOT/lib/deploy.sh"
. "$BEAUT_ROOT/lib/cli.sh"

beaut_cli_main "$@"
