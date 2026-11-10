#!/usr/bin/env bash
# lib/personal_tree.sh — the personal tree: SVR_NAME symlink -> git-backed SVR_ROOT.
#
#   SVR_ROOT (~/.svr)                         data directory, separate git repo
#   $PUBLISHED_ROOT/$SVR_NAME -> SVR_ROOT     symlink served as /<SVR_NAME>/
#   $SVR_ROOT/scripts -> $PUBLISHED_ROOT/scripts
#
# SVR_NAME is configured or generated once and persisted in state/svr_name.
set -uo pipefail

PERSONAL_TREE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F has_command >/dev/null 2>&1; then
  . "$PERSONAL_TREE_LIB_DIR/core.sh"
fi
. "$PERSONAL_TREE_LIB_DIR/passphrase.sh"

personal_tree_name_file() {
  printf '%s/svr_name' "${STATE_DIR:?STATE_DIR is required}"
}

personal_tree_validate_name() {
  local name="${1:-}"
  [[ -n "$name" && "$name" != "." && "$name" != ".." ]] || return 1
  [[ "$name" =~ ^[A-Za-z0-9._-]{1,64}$ ]]
}

# Resolve SVR_NAME: explicit value, then the persisted file, then generate once.
personal_tree_name() {
  local file existing desired
  file="$(personal_tree_name_file)"
  if [[ -n "${SVR_NAME:-}" ]]; then
    personal_tree_validate_name "$SVR_NAME" || {
      printf 'invalid SVR_NAME: %s ([A-Za-z0-9._-], max 64)\n' "$SVR_NAME" >&2
      return 1
    }
    desired="$SVR_NAME"
  elif [[ -s "$file" ]]; then
    existing="$(tr -d '[:space:]' < "$file")"
    personal_tree_validate_name "$existing" && { printf '%s' "$existing"; return 0; }
    desired="$(passphrase_random_alphanumeric 8)"
  else
    desired="$(passphrase_random_alphanumeric 8)"
  fi

  existing=''
  [[ -s "$file" ]] && existing="$(tr -d '[:space:]' < "$file")"
  if [[ "$desired" != "$existing" ]]; then
    mkdir -p -- "$(dirname "$file")" || return 1
    (umask 077; printf '%s\n' "$desired" > "$file") || return 1
    chmod 600 "$file" 2>/dev/null || true
  fi
  printf '%s' "$desired"
}

personal_tree_root() {
  printf '%s' "${SVR_ROOT:-${HOME:?HOME is required}/.svr}"
}

personal_tree_url_path() {
  local name
  name="$(personal_tree_name)" || return 1
  printf '/%s' "$name"
}

personal_tree_site_base() {
  printf '%s' "${PUBLISHED_ROOT:-${SERVICE_ROOT:?SERVICE_ROOT is required}/site}"
}

# Mirror the tree in the published root and link the public scripts inside it.
# An optional journal root is linked as $SVR_ROOT/journal (usually ~/journal).
personal_tree_link_site() {
  local journal_root="${1:-}" root name base scripts git_dir
  root="$(personal_tree_root)" || return 1
  name="$(personal_tree_name)" || return 1
  base="$(personal_tree_site_base)" || return 1
  mkdir -p -- "$base" || return 1

  if [[ -e "$base/$name" && ! -L "$base/$name" ]]; then
    log warn "$base/$name exists and is not a symlink; not replacing"
  else
    ln -sfn -- "$root" "$base/$name"
  fi

  # Working inside the repository: keep the generated symlink out of git.
  if [[ -n "${PROJECT_ROOT:-}" && "$base" == "${SITE_DIRECTORY:-}" ]]; then
    git_dir="$(git -C "$PROJECT_ROOT" rev-parse --git-dir 2>/dev/null || true)"
    if [[ -n "$git_dir" ]]; then
      [[ "$git_dir" = /* ]] || git_dir="$PROJECT_ROOT/$git_dir"
      grep -qxF "site/$name" "$git_dir/info/exclude" 2>/dev/null \
        || printf 'site/%s\n' "$name" >> "$git_dir/info/exclude" 2>/dev/null || true
    fi
  fi

  if [[ -n "$journal_root" && ( ! -e "$root/journal" || -L "$root/journal" ) ]]; then
    ln -sfn -- "$journal_root" "$root/journal"
  fi

  scripts="$base/scripts"
  [[ -d "$scripts" ]] || return 0
  if [[ -e "$root/scripts" && ! -L "$root/scripts" ]]; then
    return 0
  fi
  ln -sfn -- "$scripts" "$root/scripts"
}

personal_tree_initialize() {
  local journal_root="${1:-}" root name fresh=0
  name="$(personal_tree_name)" || return 1
  root="$(personal_tree_root)" || return 1
  [[ -d "$root" && -n "$(ls -A -- "$root" 2>/dev/null)" ]] || fresh=1
  mkdir -p -- "$root" || return 1

  if has_command git; then
    git_init "$root" || return 1
    git_accept_pushes "$root"
  fi

  # Seed only an empty tree: an existing checkout keeps its own content.
  if (( fresh )); then
    mkdir -p -- "$root/notes"
    chmod 700 "$root" "$root/notes" 2>/dev/null || true
    cat > "$root/DEFAULT.sh" <<'DEFAULT_SCRIPT'
#!/bin/sh
# Personal tree entry.
printf 'beaut personal tree\n'
printf 'journal: journal/YYYY/MM/DD/<subfolder>/<name>.md\n'
DEFAULT_SCRIPT
    chmod 755 "$root/DEFAULT.sh"
    printf 'echo hello-world\n' > "$root/command"
    chmod 600 "$root/command" 2>/dev/null || true
  fi

  personal_tree_link_site "$journal_root" || return 1
  if (( fresh )) && has_command git; then
    git_commit_all "$root" "svr: init"
  fi
  printf '%s' "$name"
}
