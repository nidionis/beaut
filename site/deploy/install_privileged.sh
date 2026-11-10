#!/usr/bin/env bash
# install_privileged.sh — install or refresh the root-owned copy of the scripts
# and its frozen config. Runs as root through the SERVICE_USER sudo grant, and
# from bootstrap.sh with the unpacked payload as SOURCE_DIRECTORY.
#
#   SOURCE_DIRECTORY       payload or $SERVICE_HOME/.beaut (default)
#   SERVICE_ROOT           paths written to the frozen config (default SOURCE_DIRECTORY)
#   ROOT_LIBRARY_DIRECTORY root-owned install prefix (/usr/local/lib/beaut)
set -euo pipefail

SOURCE_DIRECTORY="${SOURCE_DIRECTORY:-${SERVICE_HOME:?SOURCE_DIRECTORY or SERVICE_HOME is required}/.beaut}"
SERVICE_ROOT="${SERVICE_ROOT:-$SOURCE_DIRECTORY}"
STATE_DIRECTORY="${STATE_DIR:-$SERVICE_ROOT/state}"
PUBLISHED_DIRECTORY="${PUBLISHED_ROOT:-$SERVICE_ROOT/site}"
ROOT_LIBRARY_DIRECTORY="${ROOT_LIBRARY_DIRECTORY:-/usr/local/lib/beaut}"

[[ -d "$SOURCE_DIRECTORY/site/scripts" ]] || {
  printf 'missing source scripts: %s\n' "$SOURCE_DIRECTORY/site/scripts" >&2
  exit 1
}
[[ -f "$SOURCE_DIRECTORY/config.env.example" ]] || {
  printf 'missing config schema: %s\n' "$SOURCE_DIRECTORY/config.env.example" >&2
  exit 1
}

if [[ "$(id -u)" -eq 0 ]]; then
  install -d -m 755 -o root -g root "$ROOT_LIBRARY_DIRECTORY"
else
  install -d -m 755 "$ROOT_LIBRARY_DIRECTORY"
fi
rm -rf -- "$ROOT_LIBRARY_DIRECTORY/site"
install -d -m 755 "$ROOT_LIBRARY_DIRECTORY/site"
cp -a "$SOURCE_DIRECTORY/site/scripts" "$ROOT_LIBRARY_DIRECTORY/site/scripts"

# Overrides first, then the schema: derived paths use ${VAR:-default}, so the
# service user's paths win and the root copy reads the same registry/keys.
printf 'SERVICE_ROOT=%s\nSTATE_DIR=%s\nPUBLISHED_ROOT=%s\n' \
  "$SERVICE_ROOT" "$STATE_DIRECTORY" "$PUBLISHED_DIRECTORY" \
  > "$ROOT_LIBRARY_DIRECTORY/config.env"
cat "$SOURCE_DIRECTORY/config.env.example" >> "$ROOT_LIBRARY_DIRECTORY/config.env"

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R root:root "$ROOT_LIBRARY_DIRECTORY"
fi
chmod -R go-w "$ROOT_LIBRARY_DIRECTORY"
find "$ROOT_LIBRARY_DIRECTORY/site/scripts" -type f -name '*.sh' -exec chmod 755 {} +
printf '[install_privileged] refreshed %s\n' "$ROOT_LIBRARY_DIRECTORY" >&2
