#!/usr/bin/env bash
# trusted.sh — parsing du fichier workers.trusted
# Format : ID \t IP_WG \t priorite_nice \t # commentaire
# Les lignes commençant par # sont ignorées.
#
# Fonctions :
#   trusted_list <file>    → affiche "ID IP_WG NICE" pour chaque ligne active
#   trusted_nice <file> <id> → affiche la priorité nice d'un worker donné
#   trusted_ip   <file> <id> → affiche l'IP WG d'un worker donné
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$LIB_DIR/.." && pwd)"

# trusted_list <file>
# Affiche les workers de confiance actifs (lignes non commentées).
trusted_list() {
  local file="${1:?fichier workers.trusted manquant}"
  [[ -f "$file" ]] || return 0
  grep -v '^\s*#' "$file" | grep -v '^\s*$' | awk -F'\t' '{print $1, $2, $3}'
}

# trusted_nice <file> <id>
# Affiche la priorité nice associée au worker $id.
trusted_nice() {
  local file="${1:?fichier manquant}"
  local id="${2:?id manquant}"
  [[ -f "$file" ]] || { echo "${NICE_GUEST:+19}"; return; }
  grep -v '^\s*#' "$file" | grep -v '^\s*$' | awk -F'\t' -v id="$id" '$1==id{print $3; exit}'
}

# trusted_ip <file> <id>
# Affiche l'IP WireGuard associée au worker $id.
trusted_ip() {
  local file="${1:?fichier manquant}"
  local id="${2:?id manquant}"
  [[ -f "$file" ]] || return
  grep -v '^\s*#' "$file" | grep -v '^\s*$' | awk -F'\t' -v id="$id" '$1==id{print $2; exit}'
}
