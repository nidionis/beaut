#!/usr/bin/env bash
# lib/state.sh — single TSV table (state/db.tsv).
# Columns: type | id | value1 | value2 | value3 | value4 | value5 | timestamp
#   type=token   : token | command | status | created_at | worker_ip | result | confirmed_at
#   type=task    : task | dataset | command | status | created_at | ... | ...
#   type=result  : token | node | result | timestamp | ... | ...
#   type=archive : day | token | node | result | timestamp | ... | ...
state_find() {
  local file="${1:?missing file}"
  local column="${2:?missing column}"
  local value="${3:?missing value}"
  awk -F'\t' -v c="$column" -v v="$value" '$c==v{print; exit}' "$file"
}

state_append() {
  local file="${1:?missing file}"; shift
  local line=""
  for field in "$@"; do
    line+="$field"$'\t'
  done
  line="${line%$'\t'}"
  printf '%s\n' "$line" >> "$file"
}

state_update() {
  local file="${1:?missing file}"
  local set_column="${2:?missing column to update}"
  local set_value="${3:?missing value}"
  local match_column="${4:?missing match column}"
  local match_value="${5:?missing match value}"
  local tmp; tmp="$(mktemp)"
  awk -F'\t' -v sc="$set_column" -v sv="$set_value" -v mc="$match_column" -v mv="$match_value" \
    'BEGIN{OFS="\t"} $mc==mv{$sc=sv} {print}' "$file" > "$tmp"
  mv "$tmp" "$file"
}

token_create() {
  local command="$1" status="$2" created_at="$3"
  local token
  token="$(new_id | tr -d '.')"
  printf 'token\t%s\t%s\t%s\t%s\t\t\t\n' "$token" "$command" "$status" "$created_at" >> "$STATE_DIR/db.tsv"
  printf '%s' "$token"
}

token_find() {
  awk -F'\t' -v t="token" -v v="$1" '$1==t && $2==v { print; exit }' "$STATE_DIR/db.tsv"
}

token_field() {
  local token="$1" column="$2"
  printf '%s' "$(state_find "$STATE_DIR/db.tsv" 2 "$token")" | cut -d $'\t' -f "$column"
}
