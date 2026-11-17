# bootstrap.sh - locate the tree, choose the config and load the small core.
set -u

_self="${BASH_SOURCE[0]}"
_self="$(readlink -f -- "$_self" 2>/dev/null || printf '%s' "$_self")"
BEAUT_ROOT="$(cd -- "$(dirname -- "$_self")/.." && pwd)"
unset _self
export BEAUT_ROOT

if [[ -z "${BEAUT_CONFIG:-}" ]]; then
  if [[ -f "$BEAUT_ROOT/conf/conf.env" ]]; then
    BEAUT_CONFIG="$BEAUT_ROOT/conf/conf.env"
  else
    BEAUT_CONFIG="$BEAUT_ROOT/conf/conf.env.example"
  fi
fi
BEAUT_CONF_DIR="$(cd -- "$(dirname -- "$BEAUT_CONFIG")" && pwd)"
: "${BEAUT_ENV:=$BEAUT_CONF_DIR/node.env}"
export BEAUT_CONFIG BEAUT_ENV BEAUT_CONF_DIR

# shellcheck source=/dev/null
for _module in common config resources http router state hub worker status doctor; do
  . "$BEAUT_ROOT/lib/$_module.sh"
done
unset _module
