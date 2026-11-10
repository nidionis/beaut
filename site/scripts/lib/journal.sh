#!/usr/bin/env bash
# lib/journal.sh — reference-compatible journal, independent of SVR_ROOT.
#
# Layout:
#   $JOURNAL_ROOT/YYYY/MM/DD/<subfolder>/<name>.md
#   $JOURNAL_ROOT/<host>/<subfolder>/<name>.md   (hard-link view)
#   $JOURNAL_ROOT/index.html                     (generated index)
#
# The root defaults to ~/journal; journal-perso uses PERSO_ROOT (by config,
# $SVR_ROOT/perso). It is a git repository when JOURNAL_GIT=1 and git is
# available: pull before an edit, commit after it, push when a remote exists.
set -uo pipefail

JOURNAL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F has_command >/dev/null 2>&1; then
  . "$JOURNAL_LIB_DIR/core.sh"
fi

journal_root() {
  if [[ -n "${JOURNAL_ROOT:-}" ]]; then
    printf '%s' "$JOURNAL_ROOT"
    return 0
  fi
  local name="${JOURNAL_DIR:-journal}"
  journal_validate_component "$name" || name=journal
  printf '%s/%s' "${JOURNAL_BASE:-${HOME:-${SERVICE_ROOT:-/tmp}}}" "$name"
}

journal_perso_root() {
  if [[ -n "${PERSO_ROOT:-}" ]]; then
    printf '%s' "$PERSO_ROOT"
    return 0
  fi
  local name="${PERSO_DIR:-perso}"
  journal_validate_component "$name" || name=perso
  printf '%s/%s' "${JOURNAL_BASE:-${HOME:-${SERVICE_ROOT:-/tmp}}}" "$name"
}

journal_date() { printf '%s' "${JOURNAL_DATE:-$(date +%F)}"; }
journal_time() { printf '%s' "${JOURNAL_TIME:-$(date +%T)}"; }
journal_user() { printf '%s' "${USER:-$(id -un 2>/dev/null || printf unknown)}"; }
journal_host() { printf '%s' "${HOST:-$(hostname 2>/dev/null || printf unknown)}"; }

journal_validate_date() {
  local date="${1:-}" month day
  [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  month="${date:5:2}" day="${date:8:2}"
  (( 10#$month >= 1 && 10#$month <= 12 )) || return 1
  (( 10#$day >= 1 && 10#$day <= 31 )) || return 1
}

journal_validate_component() {
  local value="${1:-}"
  [[ -n "$value" && "$value" != "." && "$value" != ".." ]] || return 1
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

journal_date_parts() {
  local date="${1:-$(journal_date)}"
  journal_validate_date "$date" || {
    printf 'invalid journal date: %s\n' "$date" >&2
    return 1
  }
  printf '%s/%s/%s' "${date:0:4}" "${date:5:2}" "${date:8:2}"
}

# Relative path inside the journal root: YYYY/MM/DD/<subfolder>/<name>.md.
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
    printf '%s\n%s\n%s\n%s\n\n' "$compact" "$(journal_time)" "$(journal_user)" "$(journal_host)"
    printf '###############################################\n\n%s\n\n' "$relative"
  } >> "$file"
}

# Per-host hard-link view; fall back to a symlink when hard links are refused.
journal_link_host() {
  local root="$1" subfolder="$2" name="$3" file="$4" link
  link="$root/$(journal_host)/$subfolder/$name.md"
  mkdir -p -- "$(dirname "$link")"
  ln -f -- "$file" "$link" 2>/dev/null || ln -sfn -- "$file" "$link"
}

# --- git --------------------------------------------------------------------
journal_git_ready() {
  [[ "${JOURNAL_GIT:-1}" == "1" ]] && has_command git && git_repo "$1"
}

journal_git_pull() { journal_git_ready "$1" || return 0; git_pull "$1"; }
journal_git_commit() { journal_git_ready "$1" || return 0; git_commit_all "$1" "$2"; }
journal_git_push() { journal_git_ready "$1" || return 0; git_push "$1"; }

journal_remote_set() {
  local root="$1" url="$2"
  [[ -n "$url" ]] || { printf 'missing git remote URL\n' >&2; return 1; }
  has_command git || { printf 'git is required for remotes\n' >&2; return 1; }
  git_init "$root" || return 1
  if git -C "$root" remote get-url origin >/dev/null 2>&1; then
    git -C "$root" remote set-url origin "$url"
  else
    git -C "$root" remote add origin "$url"
  fi
}

# Resolve "server" to user@host:path. JOURNAL_REMOTE_PATH/PERSO_REMOTE_PATH are
# exact repo paths on the server; the defaults are ~/journal and ~/perso.
journal_remote_resolve() {
  local remote="${1:-}" root="${2:-$(journal_root)}" host user repo_path port
  case "$remote" in
    ''|none|0) return 1 ;;
    server|hidden)
      host="${JOURNAL_REMOTE_HOST:-${SERVER_HOST:-}}"
      user="${JOURNAL_REMOTE_USER:-${SERVICE_USER:-$(journal_user)}}"
      [[ -n "$host" ]] || {
        printf 'JOURNAL_REMOTE=server requires JOURNAL_REMOTE_HOST or SERVER_HOST\n' >&2
        return 1
      }
      if [[ "$root" == "$(journal_perso_root)" ]]; then
        repo_path="${PERSO_REMOTE_PATH:-~/${PERSO_DIR:-perso}}"
      else
        repo_path="${JOURNAL_REMOTE_PATH:-~/${JOURNAL_DIR:-journal}}"
      fi
      port="${JOURNAL_SSH_PORT:-${SSH_PORT:-}}"
      if [[ -n "$port" && "$port" != "22" ]]; then
        printf 'ssh://%s@%s:%s/%s' "$user" "$host" "$port" "${repo_path#/}"
      else
        printf '%s@%s:%s' "$user" "$host" "$repo_path"
      fi
      ;;
    *)
      printf '%s' "$remote"
      ;;
  esac
}

journal_remote_get() {
  local root="$1"
  git_repo "$root" || return 1
  git -C "$root" remote get-url origin 2>/dev/null
}

journal_sync() {
  local root="${1:-$(journal_root)}"
  journal_git_pull "$root"
  journal_git_push "$root"
}

# --- writes -----------------------------------------------------------------
# Start one entry: pull, create the date folder and the reference header.
journal_begin() {
  local root="$1" subfolder="$2" name="$3"
  journal_relative="$(journal_relative_path "$subfolder" "$name")" || return 1
  journal_file="$root/$journal_relative"
  journal_git_pull "$root"
  mkdir -p -- "$(dirname "$journal_file")" || return 1
  chmod 700 -- "$(dirname "$journal_file")" 2>/dev/null || true
  [[ -f "$journal_file" ]] || journal_write_header "$journal_file" "$journal_relative" || return 1
}

# Finish one entry: host view, index, commit, push.
journal_finish() {
  local root="$1" subfolder="$2" name="$3"
  chmod 600 "$journal_file" 2>/dev/null || true
  journal_link_host "$root" "$subfolder" "$name" "$journal_file"
  journal_refresh_index "$root"
  journal_git_commit "$root" "journal: $journal_relative"
  journal_git_push "$root"
  printf '%s' "$journal_file"
}

journal_write_text() {
  local root="$1" subfolder="$2" name="$3" text="${4:-}" remote="${5:-${JOURNAL_REMOTE:-}}"
  [[ -n "$text" ]] || {
    printf 'journal entry text is required\n' >&2
    return 1
  }
  journal_initialize_root "$root" "$remote" || return 1
  text="${text//$'\n'/ }"
  text="${text//$'\t'/ }"
  journal_begin "$root" "$subfolder" "$name" || return 1
  printf '%s\n' "$text" >> "$journal_file"
  journal_finish "$root" "$subfolder" "$name"
}

journal_add() {
  journal_write_text "$(journal_root)" "${JOURNAL_SUBFOLDER:-notes}" \
    "${JOURNAL_FILE_NAME:-notes}" "${1:-}"
}

# Open (or create) one entry in $EDITOR, then commit and push.
journal_open_at() {
  local root="$1" default_subfolder="$2"; shift 2
  local subfolder name editor
  case $# in
    1) subfolder="$default_subfolder"; name="$1" ;;
    2) subfolder="$1"; name="$2" ;;
    *)
      printf 'usage: journal [subfolder] <name>\n' >&2
      return 1
      ;;
  esac
  journal_begin "$root" "$subfolder" "$name" || return 1
  if [[ -n "${JOURNAL_TEXT:-}" ]]; then
    printf '%s\n' "$JOURNAL_TEXT" >> "$journal_file"
  else
    editor="${JOURNAL_EDITOR:-${EDITOR:-vi}}"
    "$editor" "$journal_file" || {
      printf 'editor failed: %s\n' "$editor" >&2
      return 1
    }
  fi
  journal_finish "$root" "$subfolder" "$name"
}

journal_open_root() {
  local root="$1" remote="$2" default_subfolder="$3"; shift 3
  journal_initialize_root "$root" "$remote" || return 1
  journal_open_at "$root" "$default_subfolder" "$@"
}

journal_open() {
  journal_open_root "$(journal_root)" "${JOURNAL_REMOTE:-}" \
    "${JOURNAL_SUBFOLDER:-notes}" "$@"
}

journal_perso_open() {
  journal_open_root "$(journal_perso_root)" "${PERSO_REMOTE:-}" \
    "${PERSO_SUBFOLDER:-fouretout}" "$@"
}

# --- listing and index ------------------------------------------------------
journal_list() {
  local limit="${1:-0}" root="${2:-$(journal_root)}" file relative host_view
  [[ -d "$root" ]] || return 0
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=0
  host_view="$root/$(journal_host)"
  while IFS= read -r file; do
    printf '%s\n' "${file#"$root"/}"
  done < <(find "$root" -type f -name '*.md' \
    ! -path "$root/.git/*" ! -path "$host_view/*" -print) \
    | sort -r | awk -v limit="$limit" 'limit == 0 || NR <= limit'
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

# --- initialization ---------------------------------------------------------
journal_initialize_root() {
  local root="$1" remote="${2:-}"
  mkdir -p -- "$root" || return 1
  chmod 700 "$root" 2>/dev/null || true
  if [[ "${JOURNAL_GIT:-1}" == "1" ]] && has_command git; then
    git_init "$root" || return 1
    # Accept pushes into this working tree (server side).
    git_accept_pushes "$root"
    if [[ -n "$remote" ]]; then
      remote="$(journal_remote_resolve "$remote" "$root")" || return 1
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

journal_push() {
  journal_git_push "${1:-$(journal_root)}"
}
