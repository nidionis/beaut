#!/usr/bin/env bash
# sync_site.sh — apply the uploaded public site to $PUBLISHED_ROOT.
#
# Usage: sync_site.sh <staging_directory> <repository_list>
#
# The staging directory contains plain site content. A top-level folder of the
# local `site/` tree that contains `.git` is not uploaded: it is listed in the
# repository list as `name<TAB>remote_url`, cloned on the first deploy and
# fast-forwarded with `git pull --ff-only` afterwards. Its working tree is then
# served statically, while dot-prefixed paths (including `.git`) stay private.
#
# Generated entries (scripts, deploy, node) are reserved and never touched.
set -euo pipefail

# Never block on an interactive credential prompt: a deploy must fail fast when
# a site repository needs credentials the server does not have.
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIRECTORY/../../scripts/lib/core.sh"
load_config

: "${PUBLISHED_ROOT:?PUBLISHED_ROOT is required}"
: "${STATE_DIR:?STATE_DIR is required}"

staging_directory="${1:?usage: sync_site.sh <staging_directory> <repository_list>}"
repository_list="${2:?usage: sync_site.sh <staging_directory> <repository_list>}"

reserved_name() {
  case "${1:-}" in
    scripts|deploy|node) return 0 ;;
    *)                    return 1 ;;
  esac
}

valid_entry_name() {
  local name="${1:-}"
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
}

validate_entry_name() {
  local name="$1" kind="${2:-entry}"
  valid_entry_name "$name" || {
    printf 'invalid site %s name: %s\n' "$kind" "$name" >&2
    return 1
  }
  reserved_name "$name" && {
    printf 'reserved site %s name: %s\n' "$kind" "$name" >&2
    return 1
  }
  return 0
}

mkdir -p -- "$PUBLISHED_ROOT" "$STATE_DIR"
manifest_file="$STATE_DIR/site_manifest"
temporary_manifest="$(mktemp)"
trap 'rm -f -- "$temporary_manifest"' EXIT

declare -A desired_entries=()

# Plain files and directories first.
while IFS= read -r -d '' entry; do
  name="$(basename -- "$entry")"
  # Dot-prefixed top-level entries (.git, .gitignore, …) are private and are
  # never published, so they are not part of the managed manifest either.
  case "$name" in
    .*) continue ;;
  esac
  validate_entry_name "$name" || exit 1
  rm -rf -- "$PUBLISHED_ROOT/$name"
  cp -a -- "$entry" "$PUBLISHED_ROOT/$name"
  desired_entries["$name"]=1
  printf '%s\n' "$name" >> "$temporary_manifest"
done < <(find "$staging_directory" -mindepth 1 -maxdepth 1 -print0)

# Git-backed entries: clone once, then fast-forward from the configured remote.
if [[ -s "$repository_list" ]]; then
  command -v git >/dev/null 2>&1 || {
    printf 'git is required to deploy site repositories\n' >&2
    exit 1
  }
  while IFS=$'\t' read -r name remote_url; do
    [[ -n "$name" ]] || continue
    validate_entry_name "$name" repository || exit 1
    [[ -n "$remote_url" ]] || {
      printf 'missing remote URL for site repository: %s\n' "$name" >&2
      exit 1
    }
    target="$PUBLISHED_ROOT/$name"
    if [[ -d "$target/.git" ]]; then
      existing_url="$(git -C "$target" config --get remote.origin.url || true)"
      if [[ "$existing_url" == "$remote_url" ]]; then
        git -C "$target" pull --quiet --ff-only
      else
        printf 'site repository %s changed remote: %s -> %s\n' \
          "$name" "${existing_url:-none}" "$remote_url" >&2
        rm -rf -- "$target"
        git clone --quiet -- "$remote_url" "$target"
      fi
    else
      rm -rf -- "$target"
      git clone --quiet -- "$remote_url" "$target"
    fi
    desired_entries["$name"]=1
    printf '%s\n' "$name" >> "$temporary_manifest"
  done < "$repository_list"
fi

# Remove entries this script managed on the previous deploy but that no longer
# exist in the repository. Anything never managed here (including generated
# directories) is preserved.
if [[ -f "$manifest_file" ]]; then
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    [[ -n "${desired_entries[$name]:-}" ]] && continue
    reserved_name "$name" && continue
    valid_entry_name "$name" || continue
    rm -rf -- "$PUBLISHED_ROOT/$name"
  done < "$manifest_file"
fi

sort -u "$temporary_manifest" > "$manifest_file"
chmod 600 "$manifest_file" 2>/dev/null || true
printf '[sync_site] applied %s entries to %s\n' \
  "$(wc -l < "$manifest_file" | tr -d '[:space:]')" "$PUBLISHED_ROOT" >&2
