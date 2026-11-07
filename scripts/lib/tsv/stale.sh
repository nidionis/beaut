#!/usr/bin/env bash
# tsv/stale.sh — définit tsv_mark_stale <file> <cutoff_timestamp>
# Marque comme "stale" les workers dont le dernier heartbeat (colonne 5) est antérieur à $cutoff.
tsv_mark_stale() {
  local file="${1:?fichier manquant}"
  local cutoff="${2:?seuil de temps manquant}"
  local tmp; tmp="$(mktemp)"
  awk -F'\t' -v c="$cutoff" 'BEGIN{OFS="\t"} $5+0 < c+0 {$6="stale"} {print}' "$file" > "$tmp"
  mv "$tmp" "$file"
}
