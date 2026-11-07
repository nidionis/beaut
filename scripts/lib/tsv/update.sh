#!/usr/bin/env bash
# tsv/update.sh — définit tsv_update <file> <set_col> <set_val> <match_col> <match_val>
# Remplace la colonne $set_col par $set_val sur toutes les lignes où $match_col==$match_val.
tsv_update() {
  local file="${1:?fichier manquant}"
  local set_col="${2:?colonne à modifier manquante}"
  local set_val="${3:?valeur manquante}"
  local match_col="${4:?colonne de correspondance manquante}"
  local match_val="${5:?valeur de correspondance manquante}"
  local tmp; tmp="$(mktemp)"
  awk -F'\t' -v sc="$set_col" -v sv="$set_val" -v mc="$match_col" -v mv="$match_val" \
    'BEGIN{OFS="\t"} $mc==mv{$sc=sv} {print}' "$file" > "$tmp"
  mv "$tmp" "$file"
}
