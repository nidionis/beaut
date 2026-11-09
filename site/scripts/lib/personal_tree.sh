#!/usr/bin/env bash
# lib/personal_tree.sh — personal tree: SVR_NAME symlink to SVR_ROOT, journal/perso.
#
# Simplified layout:
#   SVR_ROOT ($SERVICE_ROOT/.svr)          — data directory, separate git repo
#   $PUBLISHED_ROOT/$SVR_NAME              — symlink -> $SVR_ROOT
#   $SVR_ROOT/journal, $SVR_ROOT/perso     — reference-compatible journals
#   $SVR_ROOT/scripts                      — symlink -> $PUBLISHED_ROOT/scripts
#
# SVR_NAME is the configured name (persisted once if empty). No hidden-path
# modes; the tree is served as a normal path /$SVR_NAME/... (handler allows the
# symlink target).
set -uo pipefail

PERSONAL_TREE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F has_command >/dev/null 2>&1; then
  . "$PERSONAL_TREE_LIB_DIR/core.sh"
fi
. "$PERSONAL_TREE_LIB_DIR/passphrase.sh"

personal_tree_name_file() {
  printf '%s' "${SVR_NAME_FILE:-${STATE_DIR:?STATE_DIR is required}/svr_name}"
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

# Resolve SVR_NAME. Priority: explicit SVR_NAME, persisted file, legacy state,
# then generate once.
personal_tree_name() {
  local file existing desired legacy_file legacy
  if [[ -n "${SVR_NAME:-}" ]]; then
    personal_tree_validate_name "$SVR_NAME" || {
      printf 'invalid SVR_NAME: %s ([A-Za-z0-9._-], max 64)\n' "$SVR_NAME" >&2
      return 1
    }
    desired="$SVR_NAME"
  else
    file="$(personal_tree_name_file)"
    if [[ -s "$file" ]]; then
      existing="$(tr -d '[:space:]' < "$file")"
      personal_tree_validate_name "$existing" && { printf '%s' "$existing"; return 0; }
    fi
    # Legacy migration: read old path/name state files.
    for legacy_file in "${SVR_PATH_FILE:-${STATE_DIR:-}/svr_path}" \
                      "${SVR_DIR_FILE:-${STATE_DIR:-}/svr_dir}"; do
      if [[ -s "$legacy_file" ]]; then
        legacy="$(tr -d '[:space:]' < "$legacy_file")"
        if [[ "$legacy" =~ ^\.?(svr-)?([A-Za-z0-9._-]+)$ ]]; then legacy="${BASH_REMATCH[2]}"; fi
        if personal_tree_validate_name "$legacy" && [[ "$legacy" =~ ^[A-Za-z0-9]{8}$ || "$legacy" == i1lf7sos ]]; then
          desired="$legacy"; break
        fi
        personal_tree_validate_name "$legacy" && desired="${desired:-$legacy}"
      fi
    done
    [[ -n "${desired:-}" ]] || desired="$(personal_tree_generate_name)"
  fi
  file="$(personal_tree_name_file)"
  existing=''; [[ -s "$file" ]] && existing="$(tr -d '[:space:]' < "$file")"
  if [[ "$desired" != "$existing" ]]; then
    personal_tree_write_name_file "$file" "$desired" || return 1
  fi
  printf '%s' "$desired"
}

# Data directory (separate git repo).
personal_tree_root() {
  if [[ -n "${SVR_ROOT:-}" ]]; then
    printf '%s' "$SVR_ROOT"
    return 0
  fi
  printf '%s/.svr' "${SERVICE_ROOT:?SERVICE_ROOT is required}"
}

# URL/path component is just the name.
personal_tree_current_path() { personal_tree_name; }
personal_tree_url_path() { local n; n="$(personal_tree_name)" || return 1; printf '/%s' "$n"; }

personal_tree_site_base() {
  if [[ -n "${PUBLISHED_ROOT:-}" ]]; then printf '%s' "$PUBLISHED_ROOT"
  elif [[ -n "${SITE_DIRECTORY:-}" && -d "${SITE_DIRECTORY:-}" ]]; then printf '%s' "$SITE_DIRECTORY"
  elif [[ -n "${SITE:-}" ]]; then printf '%s' "$SITE"
  else printf '%s/site' "${SERVICE_ROOT:?SERVICE_ROOT is required}"; fi
}

personal_tree_default_script() {
  cat <<'DEFAULT_SCRIPT'
#!/bin/sh
# Personal tree entry.
printf 'beaut personal tree\n'
printf 'journal: journal/YYYY/MM/DD/<subfolder>/<name>.md\n'
DEFAULT_SCRIPT
}

personal_tree_git() {
  git -C "$1" -c user.name="${JOURNAL_GIT_NAME:-beaut}" \
    -c user.email="${JOURNAL_GIT_EMAIL:-beaut@localhost}" "${@:2}"
}

# Ensure SVR_ROOT is a git repo (separate from beaut).
personal_tree_ensure_repo() {
  local root
  root="$(personal_tree_root)" || return 1
  mkdir -p -- "$root" || return 1
  if [[ "${JOURNAL_GIT:-1}" == "0" ]] || ! has_command git; then return 0; fi
  if [[ -e "$root/.git" ]]; then return 0; fi
  git -C "$root" init -q -b main || git -C "$root" init -q || return 1
  personal_tree_git "$root" commit -q --allow-empty -m 'svr: init' >/dev/null 2>&1 || true
}

# Migrate legacy data dirs into SVR_ROOT.
personal_tree_migrate_into() {
  local root="$1" src
  if [[ -d "$root/diary" && ! -e "$root/journal" ]]; then mv -- "$root/diary" "$root/journal" || true; fi
  for src in "${SERVICE_ROOT:+$SERVICE_ROOT/svr}"; do
    [[ -n "$src" && -d "$src" && "$src" != "$root" ]] || continue
    [[ -d "$src/journal" && ! -e "$root/journal" ]] && cp -a -- "$src/journal" "$root/journal"
    [[ -d "$src/diary" && ! -e "$root/journal" ]] && cp -a -- "$src/diary" "$root/journal"
    [[ -d "$src/perso" && ! -e "$root/perso" ]] && cp -a -- "$src/perso" "$root/perso"
    [[ -d "$src/notes" && ! -e "$root/notes" ]] && cp -a -- "$src/notes" "$root/notes"
  done
  if [[ -n "${SERVICE_ROOT:-}" ]]; then
    for src in "$SERVICE_ROOT"/.svr-* "$SERVICE_ROOT"/site/*; do
      [[ -d "$src" && "$src" != "$root" && ! -L "$src" ]] || { [[ -L "$src" ]] || continue; }
      # resolve symlinked legacy worktree/dir
      local real="$src"
      [[ -L "$src" ]] && real="$(readlink -f -- "$src" 2>/dev/null || echo "$src")"
      [[ -d "$real" && "$real" != "$root" ]] || continue
      # only migrate plausible svr data dirs
      [[ -d "$real/journal" || -d "$real/perso" || -d "$real/diary" || -f "$real/DEFAULT.sh" ]] || continue
      [[ -e "$real/.git/worktrees" ]] && continue  # don't treat random dirs
      [[ -d "$real/journal" && ! -e "$root/journal" ]] && cp -a -- "$real/journal" "$root/journal"
      [[ -d "$real/diary" && ! -e "$root/journal" ]] && cp -a -- "$real/diary" "$root/journal"
      [[ -d "$real/perso" && ! -e "$root/perso" ]] && cp -a -- "$real/perso" "$root/perso"
      [[ -d "$real/notes" && ! -e "$root/notes" ]] && cp -a -- "$real/notes" "$root/notes"
    done
  fi
  if [[ -d "$root/diary" && ! -e "$root/journal" ]]; then mv -- "$root/diary" "$root/journal" || true; fi
}

# Link $PUBLISHED_ROOT/$SVR_NAME -> $SVR_ROOT and $SVR_ROOT/scripts -> site scripts.
personal_tree_link_site() {
  local root name base scripts link target root_real
  root="$(personal_tree_root)" || return 1
  name="$(personal_tree_name)" || return 1
  base="$(personal_tree_site_base)" || return 1
  [[ -d "$base" ]] || mkdir -p -- "$base" || return 0
  root_real="$(realpath -m -- "$root" 2>/dev/null || printf '%s' "$root")"

  # Create/update $base/$name symlink to SVR_ROOT.
  if [[ -e "$base/$name" && ! -L "$base/$name" && "$base/$name" != "$root_real" ]]; then
    # Old worktree directory -> convert to symlink (migrate data into SVR_ROOT).
    if [[ -f "$base/$name/.git" ]] && has_command git; then
      local gitdir repo_dir
      gitdir="$(sed -n 's/^gitdir: //p' "$base/$name/.git" 2>/dev/null || true)"
      # Copy data from worktree into SVR_ROOT (excluding .git file).
      if [[ -d "$root" ]]; then
        (cd "$base/$name" && tar cf - --exclude='.git' .) | (cd "$root" && tar xf -) 2>/dev/null || true
      fi
      # Remove worktree registration.
      if [[ -n "$gitdir" && -d "$gitdir" ]]; then
        repo_dir="$(cd "$gitdir/../.." 2>/dev/null && pwd -P)" || repo_dir=""
        [[ -n "$repo_dir" ]] && git -C "$repo_dir" worktree remove --force "$base/$name" >/dev/null 2>&1 \
          || git -C "$repo_dir" worktree prune >/dev/null 2>&1 || true
      fi
      rm -rf -- "$base/$name"
      ln -sfn -- "$root" "$base/$name"
    else
      log warn "site path $base/$name exists and is not a symlink; not replacing"
    fi
  else
    ln -sfn -- "$root" "$base/$name"
  fi

  # Exclude from beaut repo git when working inside the source tree.
  if [[ -n "${SITE_DIRECTORY:-}" && "$base" == "$SITE_DIRECTORY" ]]; then
    local git_dir
    git_dir="$(git -C "$(dirname "$SITE_DIRECTORY")" rev-parse --git-dir 2>/dev/null || true)"
    if [[ -n "$git_dir" ]]; then
      [[ "$git_dir" = /* ]] || git_dir="$(dirname "$SITE_DIRECTORY")/$git_dir"
      grep -qxF "site/$name" "$git_dir/info/exclude" 2>/dev/null \
        || printf 'site/%s\n' "$name" >> "$git_dir/info/exclude" 2>/dev/null || true
    fi
  fi

  scripts=""
  [[ -d "$base/scripts" ]] && scripts="$base/scripts"
  [[ -z "$scripts" && -n "${PUBLISHED_ROOT:-}" && -d "${PUBLISHED_ROOT}/scripts" ]] && scripts="${PUBLISHED_ROOT}/scripts"
  [[ -z "$scripts" && -n "${SITE_DIRECTORY:-}" && -d "${SITE_DIRECTORY}/scripts" ]] && scripts="${SITE_DIRECTORY}/scripts"
  if [[ -n "$scripts" ]]; then
    if [[ -e "$root/scripts" && ! -L "$root/scripts" ]]; then :; else
      ln -sfn -- "$scripts" "$root/scripts"
    fi
  fi
}

personal_tree_initialize() {
  local root name
  name="$(personal_tree_name)" || return 1
  root="$(personal_tree_root)" || return 1
  mkdir -p -- "$root" || return 1
  personal_tree_ensure_repo || return 1
  personal_tree_migrate_into "$root"
  mkdir -p -- "$root/notes"
  chmod 700 "$root" "$root/notes" 2>/dev/null || true
  if [[ ! -f "$root/DEFAULT.sh" ]]; then
    personal_tree_default_script > "$root/DEFAULT.sh"
    chmod 755 "$root/DEFAULT.sh"
  fi
  personal_tree_link_site
  printf '%s' "$name"
}

# Backcompat aliases
personal_tree_repo() { personal_tree_root; }
personal_tree_directory_name() { personal_tree_name; }
personal_tree_migrate() { :; }
personal_tree_legacy_root() { [[ -n "${SERVICE_ROOT:-}" ]] && printf '%s/svr' "$SERVICE_ROOT"; }
personal_tree_published_root() { printf '%s' "${PUBLISHED_ROOT:-${SITE:-}}"; }
personal_tree_match_path() {
  local url_path="${1:-}" hidden
  hidden="$(personal_tree_name 2>/dev/null)" || return 1
  case "$url_path" in
    "$hidden") printf ''; return 0 ;;
    "$hidden"/*) printf '%s' "${url_path#"$hidden"/}"; return 0 ;;
  esac
  return 1
}
