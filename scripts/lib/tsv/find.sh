#!/usr/bin/env bash
# tsv/find.sh — définit tsv_find <file> <col> <val>
# Affiche la première ligne où la colonne $col vaut $val.
tsv_find() {
  local file="${1:?fichier manquant}"
  local col="${2:?colonne manquante}"
  local val="${3:?valeur manquante}"
  awk -F'\t' -v c="$col" -v v="$val" '$c==v{print; exit}' "$file"
}
