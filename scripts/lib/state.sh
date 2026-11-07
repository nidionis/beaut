#!/usr/bin/env bash
# lib/state.sh — TSV unique (state/db.tsv)
# Colonnes : type | id | valeur1 | valeur2 | valeur3 | valeur4 | valeur5 | ts
#   type=token : token | commande | statut | created_at | worker_ip | resultat | confirme_at
#   type=task  : task | dataset | commande | statut | created_at | ... | ...
#   type=result : token | node | resultat | ts | ... | ... | ...
#   type=archive : jour | token | node | resultat | ts | ... | ...
tsv_find() {
  local file="${1:?fichier manquant}"
  local col="${2:?colonne manquante}"
  local val="${3:?valeur manquante}"
  awk -F'\t' -v c="$col" -v v="$val" '$c==v{print; exit}' "$file"
}

tsv_append() {
  local file="${1:?fichier manquant}"; shift
  local line=""
  for champ in "$@"; do
    line+="$champ"$'\t'
  done
  line="${line%$'\t'}"
  printf '%s\n' "$line" >> "$file"
}

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
