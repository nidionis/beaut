#!/usr/bin/env bash
# tsv/append.sh — définit tsv_append <file> <champ1> <champ2> ...
# Ajoute une ligne TSV à la fin du fichier.
tsv_append() {
  local file="${1:?fichier manquant}"
  shift
  local line=""
  for champ in "$@"; do
    line+="$champ"$'\t'
  done
  line="${line%$'\t'}"
  printf '%s\n' "$line" >> "$file"
}
