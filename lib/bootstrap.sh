# bootstrap.sh - locate the tree, choose the config and load function modules.
#
# This file is sourced by the CLI and by the argument-free entrypoints in bin/.
# It does not interpret command-line arguments.

_self="${BASH_SOURCE[0]}"
_self="$(readlink -f -- "$_self" 2>/dev/null || printf '%s' "$_self")"
BEAUT_ROOT="$(cd -- "$(dirname -- "$_self")/.." && pwd)"
unset _self
export BEAUT_ROOT

: "${BEAUT_CONFIG:=$BEAUT_ROOT/conf.env}"
: "${BEAUT_ENV:=$HOME/.beaut/node.env}"
export BEAUT_CONFIG BEAUT_ENV

# shellcheck source=/dev/null
for _module in common config resources http site hub worker transport service status doctor; do
  . "$BEAUT_ROOT/lib/$_module.sh"
done
unset _module
