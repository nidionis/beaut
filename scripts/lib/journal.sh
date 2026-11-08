#!/usr/bin/env bash
# lib/journal.sh — tiny Markdown journal inside the hidden personal tree
# (sourced). One file per day; entries are appended, never rewritten.
#
#   $JOURNAL_DIRECTORY/YYYY-MM-DD.md
#   # YYYY-MM-DD
#
#   - HH:MM text
set -uo pipefail

JOURNAL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F has_command >/dev/null 2>&1; then
  . "$JOURNAL_LIB_DIR/core.sh"
fi
if ! declare -F personal_tree_root >/dev/null 2>&1; then
  . "$JOURNAL_LIB_DIR/personal_tree.sh"
fi

journal_directory() {
  printf '%s' "${JOURNAL_DIRECTORY:-$(personal_tree_root)/diary}"
}

journal_date() {
  printf '%s' "${JOURNAL_DATE:-$(date +%F)}"
}

journal_time() {
  printf '%s' "${JOURNAL_TIME:-$(date +%H:%M)}"
}

journal_validate_date() {
  [[ "${1:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

journal_file_for_date() {
  local date="${1:-$(journal_date)}"
  journal_validate_date "$date" || {
    printf 'invalid journal date: %s\n' "$date" >&2
    return 1
  }
  printf '%s/%s.md' "$(journal_directory)" "$date"
}

# Append one entry to today's (or JOURNAL_DATE's) Markdown file and print it.
journal_add() {
  local text="${1:-}" date time file
  [[ -n "$text" ]] || {
    printf 'journal entry text is required\n' >&2
    return 1
  }
  text="${text//$'\n'/ }"
  text="${text//$'\t'/ }"
  date="$(journal_date)"
  journal_validate_date "$date" || return 1
  time="$(journal_time)"
  file="$(journal_file_for_date "$date")" || return 1

  mkdir -p -- "$(dirname "$file")"
  chmod 700 "$(dirname "$file")" 2>/dev/null || true
  if [[ ! -f "$file" ]]; then
    printf '# %s\n\n' "$date" > "$file"
  elif [[ -s "$file" ]]; then
    local last_byte
    last_byte="$(tail -c 1 -- "$file" 2>/dev/null || true)"
    [[ -z "$last_byte" ]] || printf '\n' >> "$file"
  fi
  printf -- '- %s %s\n' "$time" "$text" >> "$file"
  chmod 600 "$file" 2>/dev/null || true
  printf '%s' "$file"
}

# List journal files, newest first. An optional count limits the output.
journal_list() {
  local limit="${1:-0}" directory
  directory="$(journal_directory)"
  [[ -d "$directory" ]] || return 0
  local -a files=()
  while IFS= read -r file; do
    files+=("$file")
  done < <(find "$directory" -maxdepth 1 -type f -name '*.md' -print | sort -r)
  (( ${#files[@]} > 0 )) || return 0
  if [[ "$limit" =~ ^[0-9]+$ ]] && (( limit > 0 && limit < ${#files[@]} )); then
    files=("${files[@]:0:limit}")
  fi
  printf '%s\n' "${files[@]}"
}

journal_show() {
  local date="${1:-$(journal_date)}" file
  file="$(journal_file_for_date "$date")" || return 1
  [[ -f "$file" ]] || {
    printf 'no journal for %s\n' "$date" >&2
    return 1
  }
  cat -- "$file"
}
