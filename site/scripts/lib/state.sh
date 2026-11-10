#!/usr/bin/env bash
# lib/state.sh — TSV helpers. state/db.tsv stores archived results and
# state/work.tsv stores the fictive ids issued by /work.
#   type=archive | day | id | node | result | timestamp
state_find() {
  local file="${1:?missing file}" column="${2:?missing column}" value="${3:?missing value}"
  [[ -f "$file" ]] || return 1
  awk -F'\t' -v c="$column" -v v="$value" '$c==v{print; exit}' "$file"
}

state_find_two() {
  local file="${1:?missing file}" first_column="${2:?missing column}" first_value="${3:?missing value}"
  local second_column="${4:?missing column}" second_value="${5:?missing value}"
  [[ -f "$file" ]] || return 1
  awk -F'\t' -v c1="$first_column" -v v1="$first_value" \
    -v c2="$second_column" -v v2="$second_value" \
    '$c1==v1 && $c2==v2{print; exit}' "$file"
}

state_has() {
  local file="${1:?missing file}" column="${2:?missing column}" value="${3:?missing value}"
  [[ -f "$file" ]] || return 1
  awk -F'\t' -v c="$column" -v v="$value" \
    '$c==v{found=1} END{exit !found}' "$file"
}

state_field() {
  local row="${1:-}" column="${2:?missing column}"
  [[ -n "$row" ]] || return 1
  printf '%s' "$row" | cut -f "$column"
}

state_append() {
  local file="${1:?missing file}"; shift
  local IFS=$'\t'
  printf '%s\n' "$*" >> "$file"
}

state_update() {
  local file="${1:?missing file}"
  local set_column="${2:?missing column to update}"
  local set_value="${3:?missing value}"
  local match_column="${4:?missing match column}"
  local match_value="${5:?missing match value}"
  local temporary_file; temporary_file="$(mktemp)"
  awk -F'\t' -v sc="$set_column" -v sv="$set_value" -v mc="$match_column" -v mv="$match_value" \
    'BEGIN{OFS="\t"} $mc==mv{$sc=sv} {print}' "$file" > "$temporary_file"
  mv -- "$temporary_file" "$file"
}

state_remove() {
  local file="${1:?missing file}"
  local match_column="${2:?missing match column}"
  local match_value="${3:?missing value}"
  local temporary_file; temporary_file="$(mktemp)"
  awk -F'\t' -v mc="$match_column" -v mv="$match_value" \
    '$mc!=mv{print}' "$file" > "$temporary_file"
  mv -- "$temporary_file" "$file"
}

state_file_init() {
  local directory="${1:?missing directory}" file="${2:?missing file}"
  mkdir -p -- "$directory"
  [[ -f "$file" ]] || : > "$file"
  chmod 700 "$directory" 2>/dev/null || true
  chmod 600 "$file" 2>/dev/null || true
}
