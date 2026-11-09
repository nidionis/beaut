#!/usr/bin/env bash
# lib/personal_tree.sh — hidden personal tree, its git repo and secret URL path.
#
# Layout (worktree model, option 2):
#   SVR_REPO ($SERVICE_ROOT/.svr)          — separate git repository
#   $PUBLISHED_ROOT/$SVR_NAME              — worktree; .git is a file pointing
#                                            into $SVR_REPO/.git/worktrees/...
#   $PUBLISHED_ROOT/$SVR_NAME/journal      — reference-compatible journal
#   $PUBLISHED_ROOT/$SVR_NAME/perso        — personal journal
#
# SVR_NAME is the canonical hidden name (8 alnum by default, persisted). It is
# both the on-disk worktree directory name and the URL prefix. SVR_PATH may
# override the URL prefix only (backcompat). Legacy SVR_DIR/SVR_ROOT/SVR_MODE
# variables are accepted for migration.
set -uo pipefail

PERSONAL_TREE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F has_command >/dev/null 2>&1; then
  . "$PERSONAL_TREE_LIB_DIR/core.sh"
fi
. "$PERSONAL_TREE_LIB_DIR/passphrase.sh"

personal_tree_name_file() {
  printf '%s' "${SVR_NAME_FILE:-${STATE_DIR:?STATE_DIR is required}/svr_name}"
}

# Legacy state files (read for migration).
personal_tree_legacy_dir_file() {
  printf '%s' "${SVR_DIR_FILE:-${STATE_DIR:?STATE_DIR is required}/svr_dir}"
}
personal_tree_legacy_path_file() {
  printf '%s' "${SVR_PATH_FILE:-${STATE_DIR:?STATE_DIR is required}/svr_path}"
}

personal_tree_validate_name() {
  local name="${1:-}"
  [[ -n "$name" && "$name" != "." && "$name" != ".." ]] || return 1
  [[ "$name" =~ ^[A-Za-z0-9._-]{1,64}$ ]]
}

personal_tree_generate_name() {
  passphrase_random_alphanumeric 8
}

personal_tree_write_name_file() {
  local file="$1" name="$2"
  mkdir -p -- "$(dirname "$file")" || return 1
  (umask 077; printf '%s\n' "$name" > "$file") || return 1
  chmod 600 "$file"
}

# The separate git repository that owns the hidden tree.
personal_tree_repo() {
  if [[ -n "${SVR_REPO:-}" ]]; then
    printf '%s' "$SVR_REPO"
  else
    printf '%s/.svr' "${SERVICE_ROOT:?SERVICE_ROOT is required}"
  fi
}

# Where the worktree is checked out. Prefer PUBLISHED_ROOT (server/site tree);
# fall back to SITE_DIRECTORY (repo source tree) only for local dev commands.
personal_tree_site_base() {
  if [[ -n "${PUBLISHED_ROOT:-}" ]]; then
    printf '%s' "$PUBLISHED_ROOT"
  elif [[ -n "${SITE_DIRECTORY:-}" && -d "${SITE_DIRECTORY:-}" ]]; then
    printf '%s' "$SITE_DIRECTORY"
  elif [[ -n "${SITE:-}" ]]; then
    printf '%s' "$SITE"
  else
    printf '%s/site' "${SERVICE_ROOT:?SERVICE_ROOT is required}"
  fi
}

# Resolve the canonical hidden name. Priority: SVR_NAME env/config, persisted
# name file, legacy SVR_DIR/SVR_PATH state, then generate once.
personal_tree_name() {
  local file existing desired legacy_file legacy
  if [[ -n "${SVR_NAME:-}" ]]; then
    personal_tree_validate_name "$SVR_NAME" || {
      printf 'invalid SVR_NAME: %s ([A-Za-z0-9._-], max 64)\n' "$SVR_NAME" >&2
      return 1
    }
    desired="$SVR_NAME"
  elif [[ -n "${SVR_DIR:-}" ]]; then
    # Backcompat: explicit SVR_DIR becomes the name.
    personal_tree_validate_name "$SVR_DIR" || {
      printf 'invalid SVR_DIR: %s ([A-Za-z0-9._-], max 64)\n' "$SVR_DIR" >&2
      return 1
    }
    desired="$SVR_DIR"
  else
    file="$(personal_tree_name_file)"
    if [[ -s "$file" ]]; then
      existing="$(tr -d '[:space:]' < "$file")"
      personal_tree_validate_name "$existing" && { printf '%s' "$existing"; return 0; }
      log warn "ignoring invalid SVR name in $file"
    fi
    # Migrate from legacy state: prefer URL path name (user-visible), else dir.
    for legacy_file in "$(personal_tree_legacy_path_file)" "$(personal_tree_legacy_dir_file)"; do
      if [[ -s "$legacy_file" ]]; then
        legacy="$(tr -d '[:space:]' < "$legacy_file")"
        # Strip leading dots/hyphens from legacy hidden dir names like .svr-xxx
        # only as a last resort; prefer keeping a clean 8-alnum path.
        if [[ "$legacy" =~ ^\.(svr-)?([A-Za-z0-9._-]+)$ ]]; then
          legacy="${BASH_REMATCH[2]}"
        fi
        if personal_tree_validate_name "$legacy"; then
          desired="$legacy"
          break
        fi
      fi
    done
    [[ -n "${desired:-}" ]] || desired="$(personal_tree_generate_name)"
  fi

  file="$(personal_tree_name_file)"
  existing=''
  [[ -s "$file" ]] && existing="$(tr -d '[:space:]' < "$file")"
  if [[ "$desired" != "$existing" ]]; then
    personal_tree_write_name_file "$file" "$desired" || return 1
    # Keep legacy files in sync for older tools.
    personal_tree_write_name_file "$(personal_tree_legacy_path_file)" "$desired" 2>/dev/null || true
  fi
  printf '%s' "$desired"
}

# The worktree path where the hidden content lives.
personal_tree_root() {
  local name
  if [[ -n "${SVR_TREE:-}" ]]; then
    printf '%s' "$SVR_TREE"
    return 0
  fi
  # Explicit absolute SVR_ROOT wins (backcompat / direct override).
  if [[ -n "${SVR_ROOT:-}" ]]; then
    printf '%s' "$SVR_ROOT"
    return 0
  fi
  name="$(personal_tree_name)" || return 1
  # Legacy/test mode: if SVR_DIR was explicitly set (mapped to name via
  # backcompat) and no worktree layout is requested, keep the old
  # $SERVICE_ROOT/$name location. New worktree mode uses the site base.
  if [[ -n "${SVR_DIR:-}" && -z "${SVR_USE_WORKTREE:-}" && -z "${SVR_REPO_EXPLICIT:-}" ]]; then
    printf '%s/%s' "${SERVICE_ROOT:?SERVICE_ROOT is required}" "$name"
    return 0
  fi
  if [[ "${SVR_LAYOUT:-worktree}" == "legacy" ]]; then
    printf '%s/%s' "${SERVICE_ROOT:?SERVICE_ROOT is required}" "$name"
    return 0
  fi
  printf '%s/%s' "$(personal_tree_site_base)" "$name"
}

# URL prefix (bare). SVR_PATH overrides; otherwise same as SVR_NAME.
personal_tree_current_path() {
  local explicit="${SVR_PATH:-}"
  if [[ -n "$explicit" ]]; then
    personal_tree_validate_name "$explicit" || {
      printf 'invalid SVR_PATH: %s ([A-Za-z0-9._-], max 64)\n' "$explicit" >&2
      return 1
    }
    printf '%s' "$explicit"
    return 0
  fi
  # Backcompat: plain mode with SVR variable.
  if [[ "${SVR_MODE:-}" == "plain" && -n "${SVR:-}" ]]; then
    personal_tree_validate_name "$SVR" || {
      printf 'SVR_MODE=plain requires a safe SVR value ([A-Za-z0-9._-], max 64)\n' >&2
      return 1
    }
    printf '%s' "$SVR"
    return 0
  fi
  if [[ "${SVR_MODE:-}" == "sha" ]]; then
    [[ -n "${SVR_SECRET:-}" ]] || {
      printf 'SVR_MODE=sha requires SVR_SECRET\n' >&2
      return 1
    }
    local sha
    sha="$(sha256_hex "beaut-svr:$SVR_SECRET")" || return 1
    printf '%s' "${sha:0:8}"
    return 0
  fi
  personal_tree_name
}

personal_tree_url_path() {
  local path
  path="$(personal_tree_current_path)" || return 1
  printf '/%s' "$path"
}

personal_tree_match_path() {
  local url_path="${1:-}" hidden
  hidden="$(personal_tree_current_path)" || return 1
  [[ -n "$hidden" ]] || return 1
  case "$url_path" in
    "$hidden") printf ''; return 0 ;;
    "$hidden"/*) printf '%s' "${url_path#"$hidden"/}"; return 0 ;;
  esac
  return 1
}

personal_tree_default_script() {
  cat <<'DEFAULT_SCRIPT'
#!/bin/sh
# Static welcome script for the hidden personal tree.
printf 'beaut personal tree\n'
printf 'journal: journal/YYYY/MM/DD/<subfolder>/<name>.md\n'
DEFAULT_SCRIPT
}

personal_tree_git() {
  git -C "$1" -c user.name="${JOURNAL_GIT_NAME:-beaut}" \
    -c user.email="${JOURNAL_GIT_EMAIL:-beaut@localhost}" "${@:2}"
}

# Ensure the separate .svr git repo exists with an initial commit.
personal_tree_ensure_repo() {
  local repo
  repo="$(personal_tree_repo)" || return 1
  if [[ -d "$repo/.git" || -f "$repo/.git" || -f "$repo/HEAD" ]]; then
    return 0
  fi
  mkdir -p -- "$repo" || return 1
  git -C "$repo" init -q -b admin || return 1
  personal_tree_git "$repo" commit -q --allow-empty -m 'svr: init' || return 1
}

# Migrate legacy data into the worktree. Sources: old SVR_ROOT dir, legacy
# $SERVICE_ROOT/svr, and the live .svr-2chm5bal-style hidden dirs.
personal_tree_migrate_into() {
  local tree="$1" legacy src
  # Legacy diary -> journal name inside the target.
  if [[ -d "$tree/diary" && ! -e "$tree/journal" ]]; then
    mv -- "$tree/diary" "$tree/journal" || true
  fi
  # Migrate old separate hidden directory (SVR_ROOT or .svr-<rand>) if it
  # exists outside the worktree and the worktree is empty/new.
  local _glob
  for src in "${SVR_ROOT_LEGACY:-}" "${SERVICE_ROOT:+$SERVICE_ROOT/svr}"; do
    [[ -n "$src" && -d "$src" && "$src" != "$tree" ]] || continue
    [[ -e "$src/.git" ]] && continue
    if [[ -d "$src/journal" && ! -e "$tree/journal" ]]; then
      cp -a -- "$src/journal" "$tree/journal"
    elif [[ -d "$src/diary" && ! -e "$tree/journal" ]]; then
      cp -a -- "$src/diary" "$tree/journal"
    fi
    if [[ -d "$src/perso" && ! -e "$tree/perso" ]]; then
      cp -a -- "$src/perso" "$tree/perso"
    fi
    if [[ -d "$src/notes" && ! -e "$tree/notes" ]]; then
      cp -a -- "$src/notes" "$tree/notes"
    fi
  done
  # Also check legacy random hidden dirs.
  if [[ -n "${SERVICE_ROOT:-}" ]]; then
    for src in "$SERVICE_ROOT"/.svr-*; do
      [[ -d "$src" && "$src" != "$tree" ]] || continue
      [[ -e "$src/.git" ]] && continue
      if [[ -d "$src/journal" && ! -e "$tree/journal" ]]; then
        cp -a -- "$src/journal" "$tree/journal"
      elif [[ -d "$src/diary" && ! -e "$tree/journal" ]]; then
        cp -a -- "$src/diary" "$tree/journal"
      fi
      if [[ -d "$src/perso" && ! -e "$tree/perso" ]]; then
        cp -a -- "$src/perso" "$tree/perso"
      fi
      if [[ -d "$src/notes" && ! -e "$tree/notes" ]]; then
        cp -a -- "$src/notes" "$tree/notes"
      fi
    done
  fi
  if [[ -d "$tree/diary" && ! -e "$tree/journal" ]]; then
    mv -- "$tree/diary" "$tree/journal" || true
  fi
  return 0
}

personal_tree_exclude_worktree() {
  local name base git_dir exclude
  name="$(personal_tree_name)" || return 0
  # Try to find the enclosing beaut repo's git dir.
  base="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd -P)" || return 0
  git_dir="$(git -C "$base" rev-parse --git-dir 2>/dev/null)" || return 0
  [[ "$git_dir" = /* ]] || git_dir="$base/$git_dir"
  exclude="$git_dir/info/exclude"
  [[ -f "$exclude" ]] || touch "$exclude" 2>/dev/null || return 0
  grep -qxF "site/$name" "$exclude" 2>/dev/null || printf 'site/%s\n' "$name" >> "$exclude"
  grep -qxF "site/$name/" "$exclude" 2>/dev/null || true
}

# Create or repair the worktree checkout.
personal_tree_ensure_worktree() {
  local repo tree name
  tree="$(personal_tree_root)" || return 1
  name="$(personal_tree_name)" || return 1
  mkdir -p -- "$(dirname "$tree")" || return 1

  # Legacy/no-git mode: plain directory, no worktree.
  if [[ "${JOURNAL_GIT:-1}" == "0" ]] || ! has_command git || [[ "${SVR_LAYOUT:-}" == "legacy" ]]; then
    mkdir -p -- "$tree"
    return 0
  fi

  repo="$(personal_tree_repo)" || return 1
  personal_tree_ensure_repo || return 1

  if [[ -f "$tree/.git" ]] || [[ -d "$tree/.git" ]]; then
    # Already a git checkout/worktree.
    :
  elif [[ -e "$tree" && ! -d "$tree" ]]; then
    printf 'personal tree path exists and is not a directory: %s\n' "$tree" >&2
    return 1
  else
    # If tree exists as a plain dir/symlink with data (legacy), preserve data,
    # create worktree, then migrate data back in.
    local tmp="" src_data="$tree"
    if [[ -L "$tree" ]]; then
      src_data="$(readlink -f -- "$tree" 2>/dev/null || echo "$tree")"
    fi
    if [[ -d "$src_data" ]] && find "$src_data" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
      tmp="${tree}.migrating.$$"
      # Copy from resolved source (handles symlinks to legacy hidden dirs).
      mkdir -p -- "$tmp"
      (cd "$src_data" && tar cf - .) | (cd "$tmp" && tar xf -) 2>/dev/null || true
    fi
    rm -rf -- "$tree" 2>/dev/null || true
    # Prune stale worktree registrations for this path/name.
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
    if ! git -C "$repo" worktree add -q -B main "$tree" 2>/dev/null; then
      git -C "$repo" worktree add -q -B main --force "$tree" 2>/dev/null || {
        # Restore tmp on failure.
        [[ -n "$tmp" && -d "$tmp" && ! -e "$tree" ]] && { rm -rf -- "$tmp"; }
        printf 'cannot create worktree: %s -> %s\n' "$repo" "$tree" >&2
        return 1
      }
    fi
    if [[ -n "$tmp" && -d "$tmp" ]]; then
      # Copy migrated content, excluding nested .git dirs (journal/perso had
      # their own repos; the single .svr repo now tracks everything).
      (cd "$tmp" && tar cf - --exclude='.git' .) | (cd "$tree" && tar xf -) 2>/dev/null || true
      # Restore top-level .git only if it was the worktree's (it won't be here)
      rm -rf -- "$tmp"
    fi
  fi
  personal_tree_exclude_worktree
  return 0
}

# In the published tree, $SCRIPTS_DIR is the public scripts. Link it inside the
# worktree so /<hidden>/scripts/ resolves. The HTTP handler allows this target.
personal_tree_link_scripts() {
  local tree scripts
  tree="$(personal_tree_root)" || return 1
  scripts=""
  if [[ -n "${PUBLISHED_ROOT:-}" && -d "${PUBLISHED_ROOT}/scripts" ]]; then
    scripts="${PUBLISHED_ROOT}/scripts"
  elif [[ -n "${SITE:-}" && -d "${SITE}/scripts" ]]; then
    scripts="${SITE}/scripts"
  elif [[ -n "${SITE_DIRECTORY:-}" && -d "${SITE_DIRECTORY}/scripts" ]]; then
    scripts="${SITE_DIRECTORY}/scripts"
  fi
  [[ -n "$scripts" && -d "$scripts" ]] || return 0
  if [[ -e "$tree/scripts" && ! -L "$tree/scripts" ]]; then
    return 0
  fi
  ln -sfn -- "$scripts" "$tree/scripts"
}

# Backcompat name used by svr.sh and tests.
# In worktree mode the tree lives at $PUBLISHED_ROOT/$name (no mirror needed).
# In legacy mode (tree outside published root) create the published mirror.
personal_tree_link_site() {
  local tree published hidden root_real link target
  tree="$(personal_tree_root)" || return 1
  hidden="$(personal_tree_current_path)" || return 1
  published="${PUBLISHED_ROOT:-${SITE:-}}"
  personal_tree_link_scripts
  [[ -n "$published" && -d "$published" ]] || return 0
  root_real="$(realpath -m -- "$tree" 2>/dev/null || printf '%s' "$tree")"
  # If the tree is already inside the published root at the right name, done.
  if [[ "$root_real" == "$(realpath -m -- "$published/$hidden" 2>/dev/null)" ]]; then
    # Drop stale mirrors pointing elsewhere? only symlinks to same real target.
    return 0
  fi
  # Legacy mirror: symlink $published/$hidden -> $tree
  for link in "$published"/*; do
    [[ -L "$link" ]] || continue
    target="$(realpath -m -- "$link" 2>/dev/null || true)"
    [[ "$target" == "$root_real" ]] && rm -f -- "$link"
  done
  if [[ -e "$published/$hidden" && ! -L "$published/$hidden" ]]; then
    log warn "site path $hidden already exists; not linking the hidden tree"
  else
    ln -sfn -- "$tree" "$published/$hidden"
  fi
}

personal_tree_initialize() {
  local tree name notes default_script
  name="$(personal_tree_name)" || return 1
  personal_tree_ensure_worktree || return 1
  tree="$(personal_tree_root)" || return 1
  personal_tree_migrate_into "$tree"
  notes="$tree/notes"
  default_script="$tree/DEFAULT.sh"
  mkdir -p -- "$notes"
  chmod 700 "$tree" "$notes" 2>/dev/null || true
  if [[ ! -f "$default_script" ]]; then
    personal_tree_default_script > "$default_script"
    chmod 755 "$default_script"
  fi
  personal_tree_link_scripts
  printf '%s' "$name"
}

# Backcompat helpers still referenced by old code/tests.
personal_tree_directory_name() { personal_tree_name; }
personal_tree_migrate() { :; }

# Additional backcompat aliases
personal_tree_generate_random_path() { personal_tree_generate_name; }
personal_tree_path_file() { personal_tree_legacy_path_file; }
personal_tree_directory_file() { personal_tree_legacy_dir_file; }
personal_tree_validate_plain_path() { personal_tree_validate_name "$@"; }
personal_tree_published_root() { printf '%s' "${PUBLISHED_ROOT:-${SITE:-}}"; }
personal_tree_legacy_root() { [[ -n "${SERVICE_ROOT:-}" ]] && printf '%s/svr' "$SERVICE_ROOT"; }
