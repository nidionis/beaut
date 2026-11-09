#!/usr/bin/env bash
# sync_site.sh — replace the published site with a freshly applied tree.
#
# Usage: sync_site.sh <staging_directory> <repository_list>
#
# The staging directory holds the plain site content. A top-level folder of the
# repository `site/` that contains `.git` is not uploaded: it is listed in the
# repository list as `name<TAB>remote_url` and cloned (or fast-forwarded) here.
#
# The new tree is built beside the live one and swapped atomically, so a failed
# deploy never leaves a half-written site. Dot-prefixed entries stay private.
set -euo pipefail

# A deploy must fail fast instead of waiting for credentials.
export GIT_TERMINAL_PROMPT=0

staging_directory="${1:?usage: sync_site.sh <staging_directory> <repository_list>}"
repository_list="${2:?usage: sync_site.sh <staging_directory> <repository_list>}"

if [[ -z "${PUBLISHED_ROOT:-}" ]]; then
  set -a
  [[ -f "$HOME/.beaut/config.env" ]] && . "$HOME/.beaut/config.env"
  [[ -f "$HOME/.beaut/config.env.example" ]] && . "$HOME/.beaut/config.env.example"
  set +a
fi
: "${PUBLISHED_ROOT:?PUBLISHED_ROOT is required}"
[[ -d "$staging_directory" ]] || {
  printf 'missing staging directory: %s\n' "$staging_directory" >&2
  exit 1
}

valid_entry_name() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || {
    printf 'invalid site %s name: %s\n' "${2:-entry}" "${1:-}" >&2
    return 1
  }
  case "${1:-}" in
    node|state|config.env|config.env.example)
      printf 'reserved site %s name: %s\n' "${2:-entry}" "$1" >&2
      return 1
      ;;
  esac
}

new_root="${PUBLISHED_ROOT}.new.$$"
backup_root="${PUBLISHED_ROOT}.old.$$"
cleanup() { rm -rf -- "$new_root" "$backup_root"; }
trap cleanup EXIT

mkdir -p -- "$(dirname "$PUBLISHED_ROOT")"
rm -rf -- "$new_root" "$backup_root"
mkdir -p -- "$new_root"

# Plain files and directories first. The repository is the source of truth;
# anything absent here disappears from the published tree after the swap.
count=0
while IFS= read -r -d '' entry; do
  name="$(basename -- "$entry")"
  case "$name" in
    .*) continue ;;
  esac
  valid_entry_name "$name" || exit 1
  cp -a -- "$entry" "$new_root/$name"
  count=$((count + 1))
done < <(find "$staging_directory" -mindepth 1 -maxdepth 1 -print0)

# Git-backed entries: reuse the existing checkout when the remote is unchanged,
# otherwise clone it from its origin.
if [[ -s "$repository_list" ]]; then
  command -v git >/dev/null 2>&1 || {
    printf 'git is required to deploy site repositories\n' >&2
    exit 1
  }
  while IFS=$'\t' read -r name remote_url; do
    [[ -n "$name" ]] || continue
    valid_entry_name "$name" repository || exit 1
    [[ -n "$remote_url" ]] || {
      printf 'missing remote URL for site repository: %s\n' "$name" >&2
      exit 1
    }
    target="$new_root/$name"
    existing="$PUBLISHED_ROOT/$name"
    if [[ -d "$existing/.git" ]] \
       && [[ "$(git -C "$existing" config --get remote.origin.url || true)" == "$remote_url" ]]; then
      cp -a -- "$existing" "$target"
      git -C "$target" pull --quiet --ff-only
    else
      git clone --quiet -- "$remote_url" "$target"
    fi
    count=$((count + 1))
  done < "$repository_list"
fi

# Atomic swap: the live tree is either the old one or the complete new one.
if [[ -e "$PUBLISHED_ROOT" ]]; then
  mv -- "$PUBLISHED_ROOT" "$backup_root"
fi
mv -- "$new_root" "$PUBLISHED_ROOT"
rm -rf -- "$backup_root"
trap - EXIT

printf '[sync_site] applied %s entries to %s\n' "$count" "$PUBLISHED_ROOT" >&2
