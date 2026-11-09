#!/usr/bin/env bash
# lib/journal.sh — reference-compatible journal inside the hidden personal tree.
#
# Layout (same idea as ~/.svr/usr/bin/journal):
#   $JOURNAL_ROOT/YYYY/MM/DD/<subfolder>/<name>.md
#   $JOURNAL_ROOT/YYYY/MM/DD/<subfolder>/<name>.md  (created with a header)
#   $JOURNAL_ROOT/<host>/<subfolder>/<name>.md       (hard-link view)
#   $JOURNAL_ROOT/index.html                         (generated index)
#
# The folder is a git repository when JOURNAL_GIT=1 and git is available:
# pull before an edit, commit after it, push when a remote exists.
set -uo pipefail

JOURNAL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F has_command >/dev/null 2>&1; then
  . "$JOURNAL_LIB_DIR/core.sh"
fi
if ! declare -F personal_tree_root >/dev/null 2>&1; then
  . "$JOURNAL_LIB_DIR/personal_tree.sh"
fi

journal_root() {
  local name
  if [[ -n "${JOURNAL_ROOT:-}" ]]; then
    printf '%s' "$JOURNAL_ROOT"
  elif [[ -n "${JOURNAL_DIRECTORY:-}" ]]; then
    printf '%s' "$JOURNAL_DIRECTORY"
  else
    # JOURNAL_DIR is a path component, not an absolute path. This also keeps
    # unrelated environment values (for example ~/.svr's JOURNAL_DIR) from
    # redirecting beaut's journal.
    name="${JOURNAL_DIR:-journal}"
    journal_validate_component "$name" || name=journal
    printf '%s/%s' "$(personal_tree_root)" "$name"
  fi
}

journal_perso_root() {
  local name
  if [[ -n "${PERSO_ROOT:-}" ]]; then
    printf '%s' "$PERSO_ROOT"
  else
    name="${PERSO_DIR:-perso}"
    journal_validate_component "$name" || name=perso
    printf '%s/%s' "$(personal_tree_root)" "$name"
  fi
}

# Historical alias.
journal_directory() {
  journal_root
}

journal_date() {
  printf '%s' "${JOURNAL_DATE:-$(date +%F)}"
}

journal_time() {
  printf '%s' "${JOURNAL_TIME:-$(date +%T)}"
}

journal_user() {
  printf '%s' "${USER:-$(id -un 2>/dev/null || printf unknown)}"
}

journal_host() {
  printf '%s' "${HOST:-$(hostname 2>/dev/null || printf unknown)}"
}

journal_validate_date() {
  local date="${1:-}"
  [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  # Reject impossible months/days and keep the path components numeric.
  local month="${date:5:2}" day="${date:8:2}"
  (( 10#$month >= 1 && 10#$month <= 12 )) || return 1
  (( 10#$day >= 1 && 10#$day <= 31 )) || return 1
}

journal_validate_component() {
  local value="${1:-}"
  [[ -n "$value" && "$value" != "." && "$value" != ".." ]] || return 1
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# YYYY/MM/DD for a date (defaults to JOURNAL_DATE/today).
journal_date_parts() {
  local date="${1:-$(journal_date)}"
  journal_validate_date "$date" || {
    printf 'invalid journal date: %s\n' "$date" >&2
    return 1
  }
  printf '%s/%s/%s' "${date:0:4}" "${date:5:2}" "${date:8:2}"
}

# Relative path inside the journal root.
journal_relative_path() {
  local subfolder="${1:?missing subfolder}" name="${2:?missing name}" date_parts
  journal_validate_component "$subfolder" || {
    printf 'invalid journal subfolder: %s\n' "$subfolder" >&2
    return 1
  }
  journal_validate_component "$name" || {
    printf 'invalid journal name: %s\n' "$name" >&2
    return 1
  }
  date_parts="$(journal_date_parts)" || return 1
  printf '%s/%s/%s.md' "$date_parts" "$subfolder" "$name"
}

journal_file_for_date() {
  local date="${1:-$(journal_date)}" \
        subfolder="${2:-${JOURNAL_SUBFOLDER:-notes}}" \
        name="${3:-notes}" date_parts
  date_parts="$(journal_date_parts "$date")" || return 1
  journal_validate_component "$subfolder" || {
    printf 'invalid journal subfolder: %s\n' "$subfolder" >&2
    return 1
  }
  journal_validate_component "$name" || {
    printf 'invalid journal name: %s\n' "$name" >&2
    return 1
  }
  printf '%s/%s/%s/%s.md' "$(journal_root)" "$date_parts" "$subfolder" "$name"
}

# Header copied from ~/.svr/usr/bin/header_journal (DATE is YYMMDD).
journal_write_header() {
  local file="$1" relative="$2" date compact
  date="$(journal_date)"
  journal_validate_date "$date" || return 1
  compact="${date:2:2}${date:5:2}${date:8:2}"
  {
    printf '%s\n' "$compact"
    printf '%s\n' "$(journal_time)"
    printf '%s\n' "$(journal_user)"
    printf '%s\n' "$(journal_host)"
    printf '\n'
    printf '###############################################\n'
    printf '\n'
    printf '%s\n' "$relative"
    printf '\n'
  } >> "$file"
}

# A per-host hard-link view of the journal, like the reference script. Fall
# back to a symlink when the filesystem refuses a hard link.
journal_link_host() {
  local root="$1" subfolder="$2" name="$3" file="$4" link
  link="$root/$(journal_host)/$subfolder/$name.md"
  mkdir -p -- "$(dirname "$link")"
  ln -f -- "$file" "$link" 2>/dev/null || ln -sfn -- "$file" "$link"
}

# --- git ------------------------------------------------------------------
journal_git_ready() {
  [[ "${JOURNAL_GIT:-1}" == "1" ]] || return 1
  has_command git || return 1
  [[ -d "$1/.git" ]]
}

journal_git_run() {
  local root="$1"; shift
  git -C "$root" \
    -c user.name="${JOURNAL_GIT_NAME:-beaut}" \
    -c user.email="${JOURNAL_GIT_EMAIL:-beaut@localhost}" "$@"
}

journal_git_pull() {
  local root="$1"
  journal_git_ready "$root" || return 0
  journal_git_run "$root" pull --rebase --autostash >/dev/null 2>&1 || true
}

journal_git_commit() {
  local root="$1" message="$2"
  journal_git_ready "$root" || return 0
  journal_git_run "$root" add -A >/dev/null 2>&1 || true
  journal_git_run "$root" commit -m "$message" >/dev/null 2>&1 || true
}

journal_git_push() {
  local root="$1"
  journal_git_ready "$root" || return 0
  journal_git_run "$root" push --set-upstream origin HEAD >/dev/null 2>&1 || true
}

journal_remote_set() {
  local root="$1" url="$2"
  [[ -n "$url" ]] || { printf 'missing git remote URL\n' >&2; return 1; }
  has_command git || { printf 'git is required for remotes\n' >&2; return 1; }
  [[ -d "$root/.git" ]] || git -C "$root" init -q
  if git -C "$root" remote get-url origin >/dev/null 2>&1; then
    git -C "$root" remote set-url origin "$url"
  else
    git -C "$root" remote add origin "$url"
  fi
}

journal_remote_get() {
  local root="$1"
  [[ -d "$root/.git" ]] || return 1
  git -C "$root" remote get-url origin 2>/dev/null
}

journal_sync() {
  local root="${1:-$(journal_root)}"
  journal_git_pull "$root"
  journal_git_push "$root"
}

# --- writes ---------------------------------------------------------------
journal_write_text() {
  local root="$1" subfolder="$2" name="$3" text="${4:-}" \
        relative file
  [[ -n "$text" ]] || {
    printf 'journal entry text is required\n' >&2
    return 1
  }
  journal_initialize_root "$root" "${JOURNAL_REMOTE:-}" || return 1
  text="${text//$'\n'/ }"
  text="${text//$'\t'/ }"
  relative="$(journal_relative_path "$subfolder" "$name")" || return 1
  file="$root/$relative"
  journal_git_pull "$root"
  mkdir -p -- "$(dirname "$file")"
  chmod 700 -- "$(dirname "$file")" 2>/dev/null || true
  if [[ ! -f "$file" ]]; then
    journal_write_header "$file" "$relative" || return 1
  fi
  printf '%s\n' "$text" >> "$file"
  chmod 600 "$file" 2>/dev/null || true
  journal_link_host "$root" "$subfolder" "$name" "$file"
  journal_refresh_index "$root"
  journal_git_commit "$root" "journal: $relative"
  journal_git_push "$root"
  printf '%s' "$file"
}

# Non-interactive convenience used by `svr journal add "<text>"`.
journal_add() {
  local text="${1:-}"
  journal_write_text "$(journal_root)" "${JOURNAL_SUBFOLDER:-notes}" \
    "${JOURNAL_FILE_NAME:-notes}" "$text"
}

# Open (or create) one entry in $EDITOR, then commit and push.
journal_open_at() {
  local root="$1" default_subfolder="$2"; shift 2
  local subfolder name relative file editor
  case $# in
    1) subfolder="$default_subfolder"; name="$1" ;;
    2) subfolder="$1"; name="$2" ;;
    *)
      printf 'usage: journal [subfolder] <name>\n' >&2
      return 1
      ;;
  esac
  relative="$(journal_relative_path "$subfolder" "$name")" || return 1
  file="$root/$relative"
  journal_git_pull "$root"
  mkdir -p -- "$(dirname "$file")"
  if [[ ! -f "$file" ]]; then
    journal_write_header "$file" "$relative" || return 1
  fi
  if [[ -n "${JOURNAL_TEXT:-}" ]]; then
    printf '%s\n' "$JOURNAL_TEXT" >> "$file"
  else
    editor="${JOURNAL_EDITOR:-${EDITOR:-vi}}"
    "$editor" "$file" || {
      printf 'editor failed: %s\n' "$editor" >&2
      return 1
    }
  fi
  chmod 600 "$file" 2>/dev/null || true
  journal_link_host "$root" "$subfolder" "$name" "$file"
  journal_refresh_index "$root"
  journal_git_commit "$root" "journal: $relative"
  journal_git_push "$root"
  printf '%s' "$file"
}

journal_open() {
  local root
  root="$(journal_root)" || return 1
  journal_initialize_root "$root" "${JOURNAL_REMOTE:-}" || return 1
  journal_open_at "$root" "${JOURNAL_SUBFOLDER:-notes}" "$@"
}

journal_perso_open() {
  local root
  root="$(journal_perso_root)" || return 1
  journal_initialize_root "$root" "${PERSO_REMOTE:-}" || return 1
  journal_open_at "$root" "${PERSO_SUBFOLDER:-fouretout}" "$@"
}

# --- listing and index ----------------------------------------------------
# List Markdown entries, newest first, excluding the host view and .git.
journal_list() {
  local limit="${1:-0}" root="${2:-$(journal_root)}" file relative host_view
  [[ -d "$root" ]] || return 0
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=0
  host_view="$root/$(journal_host)"
  {
    while IFS= read -r file; do
      relative="${file#"$root"/}"
      printf '%s\n' "$relative"
    done < <(find "$root" -type f -name '*.md' \
      ! -path "$root/.git/*" ! -path "$host_view/*" -print)
  } | sort -r | awk -v limit="$limit" 'limit == 0 || NR <= limit'
}

journal_show() {
  local date="${1:-$(journal_date)}" subfolder="${2:-}" name="${3:-}" \
        root date_parts directory file
  root="$(journal_root)" || return 1
  date_parts="$(journal_date_parts "$date")" || return 1
  directory="$root/$date_parts"
  if [[ -n "$name" ]]; then
    subfolder="${subfolder:-${JOURNAL_SUBFOLDER:-notes}}"
    journal_validate_component "$subfolder" || return 1
    journal_validate_component "$name" || return 1
    file="$directory/$subfolder/$name.md"
    [[ -f "$file" ]] || {
      printf 'no journal for %s/%s/%s\n' "$date" "$subfolder" "$name" >&2
      return 1
    }
    cat -- "$file"
    return 0
  fi
  [[ -d "$directory" ]] || {
    printf 'no journal for %s\n' "$date" >&2
    return 1
  }
  find "$directory" -type f -name '*.md' -print | sort | while IFS= read -r file; do
    cat -- "$file"
  done
}

journal_refresh_index() {
  local root="${1:-$(journal_root)}" relative
  [[ -d "$root" ]] || return 0
  {
    printf '<!doctype html>\n<html lang="en"><head><meta charset="utf-8">\n'
    printf '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
    printf '<title>journal</title><link rel="stylesheet" href="/style.css"></head><body><main>\n'
    printf '<h1>journal</h1>\n<ul>\n'
    while IFS= read -r relative; do
      printf '<li><a href="%s">%s</a></li>\n' "$relative" "${relative%.md}"
    done < <(journal_list 0 "$root")
    printf '</ul>\n</main></body></html>\n'
  } > "$root/index.html"
  chmod 600 "$root/index.html" 2>/dev/null || true
}

# --- initialization -------------------------------------------------------
journal_initialize_root() {
  local root="$1" remote="$2"
  mkdir -p -- "$root"
  chmod 700 "$root" 2>/dev/null || true
  if [[ "${JOURNAL_GIT:-1}" == "1" ]] && has_command git; then
    [[ -d "$root/.git" ]] || git -C "$root" init -q
    if [[ -n "$remote" ]]; then
      journal_remote_set "$root" "$remote" || return 1
    fi
  fi
  journal_refresh_index "$root"
  journal_git_commit "$root" "journal: initialize"
  journal_git_push "$root"
}

journal_initialize() {
  journal_initialize_root "$(journal_root)" "${JOURNAL_REMOTE:-}"
}

journal_perso_initialize() {
  journal_initialize_root "$(journal_perso_root)" "${PERSO_REMOTE:-}"
}
