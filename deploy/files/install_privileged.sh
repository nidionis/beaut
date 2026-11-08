#!/usr/bin/env bash
# install_privileged.sh — refresh the root-owned privileged copy and its frozen
# config. Runs as root through the SERVICE_USER sudo grant.
#
# SERVICE_HOME is passed explicitly because sudo resets HOME to the root home:
#   sudo -n env SERVICE_HOME="$HOME" bash install_privileged.sh
set -euo pipefail

: "${SERVICE_HOME:?SERVICE_HOME is required}"

ROOT_LIBRARY_DIRECTORY="${ROOT_LIBRARY_DIRECTORY:-/usr/local/lib/beaut}"
SOURCE_DIRECTORY="$SERVICE_HOME/.beaut"

[[ -d "$SOURCE_DIRECTORY/scripts" ]] || {
  printf 'missing source scripts: %s\n' "$SOURCE_DIRECTORY/scripts" >&2
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
rm -rf -- "$ROOT_LIBRARY_DIRECTORY/scripts"
cp -a "$SOURCE_DIRECTORY/scripts" "$ROOT_LIBRARY_DIRECTORY/scripts"

# Overrides first, then the schema: derived paths use ${VAR:-default}, so the
# service user's state wins and the root copy reads the same registry/keys.
printf 'SERVICE_ROOT=%s\nSTATE_DIR=%s\nPUBLISHED_ROOT=%s\n' \
  "$SOURCE_DIRECTORY" "$SOURCE_DIRECTORY/state" "$SOURCE_DIRECTORY/shared" \
  > "$ROOT_LIBRARY_DIRECTORY/config.env"
cat "$SOURCE_DIRECTORY/config.env.example" >> "$ROOT_LIBRARY_DIRECTORY/config.env"

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R root:root "$ROOT_LIBRARY_DIRECTORY"
fi
chmod -R go-w "$ROOT_LIBRARY_DIRECTORY"
find "$ROOT_LIBRARY_DIRECTORY/scripts" -type f -name '*.sh' -exec chmod 755 {} +

printf '[install_privileged] refreshed %s\n' "$ROOT_LIBRARY_DIRECTORY" >&2
