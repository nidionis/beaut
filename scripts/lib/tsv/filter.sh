#!/usr/bin/env bash
# tsv/filter.sh — définit tsv_filter <file> <status_col> <status_val>
# Affiche toutes les lignes où la colonne $status_col vaut $status_val.
tsv_filter() {
  local file="${1:?fichier manquant}"
  local status_col="${2:?colonne de statut manquante}"
  local status_val="${3:?valeur de statut manquante}"
  awk -F'\t' -v c="$status_col" -v v="$status_val" '$c==v{print}' "$file"
}
