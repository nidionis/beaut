#!/usr/bin/env bash
# tsv/field.sh — définit tsv_field <line> <col>
# Affiche la colonne $col de la ligne fournie sur stdin ou en argument.
tsv_field() {
  local col="${1:?colonne manquante}"
  local line="${2:-}"
  if [[ -z "$line" ]]; then
    line="$(cat)"
  fi
  awk -F'\t' -v c="$col" '{print $c}' <<<"$line"
}
