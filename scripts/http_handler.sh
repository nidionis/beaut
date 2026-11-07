#!/usr/bin/env bash
# http_handler.sh — gestionnaire HTTP côté SERVEUR (une connexion = un handler).
# Le serveur n'exécute rien : il sert des fichiers/scripts, crée et valide des tokens.
#
# Routes dynamiques (prioritaires) :
#   GET  /work          -> crée un token, renvoie le token
#   GET  /work/<token>  -> renvoie la commande associée au token
#   POST /done/<token>  -> enregistre le résultat lié au token
#   POST /get           -> requête dataset (corps cle=val&cle=val)
#
# Route statique (tout le reste) : le path reflète l'arborescence $HTTP_FILE_ROOT
#   /a/b/c              -> $HTTP_FILE_ROOT/a/b/c            (fichier)
#   /a/b                -> $HTTP_FILE_ROOT/a/b/DEFAU*.sh    (dossier -> défaut)
set -uo pipefail
export LC_ALL=C

SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SDIR/lib/core.sh"
load_config

STATE_DIR="${STATE_DIR:-$DIR/state}"
DB="$STATE_DIR/db.tsv"
mkdir -p "$STATE_DIR"
[[ -f "$DB" ]] || : > "$DB"

# --- réponses HTTP ----------------------------------------------------------
raison() {
  case "$1" in
    200) printf 'OK' ;;
    400) printf 'Bad Request' ;;
    403) printf 'Forbidden' ;;
    404) printf 'Not Found' ;;
    410) printf 'Gone' ;;
    *)   printf 'OK' ;;
  esac
}

repondre() {
  local code="$1" corps="${2:-}"
  printf 'HTTP/1.1 %s %s\r\nContent-Length: %s\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n%s' \
    "$code" "$(raison "$code")" "${#corps}" "$corps"
}

diffuser() {
  local fichier="$1" taille
  taille="$(wc -c < "$fichier")"
  printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n' "$taille"
  cat -- "$fichier"
}

# --- lecture de la requête --------------------------------------------------
# 1. ligne de requête : METHODE /chemin HTTP/1.1
IFS= read -r -t 5 ligne || exit 0
ligne="${ligne%$'\r'}"
methode="${ligne%% *}"
chemin="${ligne#* }"; chemin="${chemin%% *}"
chemin="${chemin#/}"; chemin="${chemin%%\?*}"

# 2. entêtes jusqu'à la ligne vide (on ne retient que Content-Length)
longueur=""
while IFS= read -r -t 5 entete; do
  entete="${entete%$'\r'}"
  [[ -z "$entete" ]] && break
  case "${entete,,}" in
    content-length:*) longueur="${entete#*:}"; longueur="${longueur//[[:space:]]/}" ;;
  esac
done

# 3. corps brut (POST uniquement ; jamais de cat bloquant sur un GET)
corps=""
if [[ "${methode^^}" == "POST" ]]; then
  if [[ "$longueur" =~ ^[0-9]+$ ]]; then
    IFS= read -r -N "$longueur" corps || true
  else
    corps="$(cat)" || true
  fi
fi

# --- extraction d'un paramètre (cle=val&cle=val) ----------------------------
get_param() {
  local cle="$1"
  printf '%s' "$corps" | awk -F'[&?]' -v k="$cle" '{
    for (i=1;i<=NF;i++) {
      split($i,a,"=")
      if (a[1]==k) { print a[2]; exit }
    }
  }'
}

# --- archivage journalier d'un résultat -------------------------------------
archive_daily() {
  local token="$1" resultat="$2"
  local jour; jour="$(date +%F)"
  local ad="$STATE_DIR/archive/$jour"
  mkdir -p "$ad"

  local total_kb dispo_kb hist_max
  total_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  dispo_kb="$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  hist_max=$(( total_kb / HIST_MEM_MAX_RATIO ))
  if [[ "$dispo_kb" -le "$hist_max" ]]; then
    log warn "archive ignorée : RAM dispo=${dispo_kb}KB <= HIST_MEM_MAX=${hist_max}KB"
    return 0
  fi

  local ts; ts="$(date +%s)"
  local node; node="$(hostname 2>/dev/null || echo unknown)"
  printf 'archive\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$jour" "$token" "$node" "$resultat" "$ts" "" "" >> "$DB"
  printf '%s\t%s\t%s\t%s\n' "$token" "$node" "$resultat" "$ts" >> "$ad/results.tsv"
}

# --- arborescence statique --------------------------------------------------
defaut_de() {
  local dossier="$1" f
  for f in "$dossier"/DEFAU*.sh; do
    if [[ -f "$f" ]]; then printf '%s' "$f"; return 0; fi
  done
  return 1
}

servir_arbre() {
  local chemin="$1" racine racine_reelle cible
  racine="${HTTP_FILE_ROOT:-}"
  if [[ -z "$racine" || ! -d "$racine" ]]; then
    repondre 404 "${ERR404:-404}"; return
  fi
  racine_reelle="$(realpath -m -- "$racine" 2>/dev/null || printf '%s' "$racine")"

  case "$chemin" in
    *..*|*\\*) repondre 404 "${ERR404:-404}"; return ;;
  esac

  cible="$(realpath -m -- "$racine/$chemin" 2>/dev/null || true)"
  if [[ -z "$cible" || ( "$cible" != "$racine_reelle" && "$cible" != "$racine_reelle"/* ) ]]; then
    repondre 404 "${ERR404:-404}"; return
  fi

  if [[ -d "$cible" ]]; then
    cible="$(defaut_de "$cible")" || { repondre 404 "${ERR404:-404}"; return; }
  fi

  if [[ -f "$cible" ]]; then
    diffuser "$cible"
  else
    repondre 404 "${ERR404:-404}"
  fi
}

# --- routage ----------------------------------------------------------------
case "$chemin" in
  work)
    token="$(uid | tr -d '.')"
    ts="$(date +%s)"
    printf 'token\t%s\techo hello-world\tpending\t%s\t\t\t\n' "$token" "$ts" >> "$DB"
    repondre 200 "$token"
    ;;
  work/*)
    token="${chemin#work/}"
    ligne_token="$(tsv_find "$DB" 2 "$token")"
    if [[ -z "$ligne_token" ]]; then
      repondre 404 "${ERR404:-404}"
    else
      type="$(printf '%s' "$ligne_token" | cut -f1)"
      statut="$(printf '%s' "$ligne_token" | cut -f4)"
      commande="$(printf '%s' "$ligne_token" | cut -f3)"
      if [[ "$type" != "token" ]]; then
        repondre 404 "${ERR404:-404}"
      elif [[ "$statut" == "pending" || "$statut" == "" ]]; then
        repondre 200 "$commande"
      else
        repondre 410 "token expiré ou utilisé ($statut)"
      fi
    fi
    ;;
  done/*)
    token="${chemin#done/}"
    if [[ -z "$token" ]]; then
      repondre 400 "token manquant"
    elif [[ -z "$(tsv_find "$DB" 2 "$token")" ]]; then
      repondre 404 "${ERR404:-404}"
    else
      archive_daily "$token" "$corps"
      tsv_update "$DB" 4 "done" 2 "$token" 2>/dev/null || true
      repondre 200 "confirmé: $token"
    fi
    ;;
  get)
    req_token="$(get_param token)"
    dataset="$(get_param dataset)"
    if [[ -z "$req_token" ]]; then
      repondre 400 "token manquant"
    elif [[ -z "$dataset" ]]; then
      repondre 400 "dataset manquant"
    elif [[ -z "$(tsv_find "$DB" 2 "$req_token")" ]]; then
      repondre 403 "token inconnu"
    else
      repondre 200 "dataset $dataset alloué au token $req_token"
    fi
    ;;
  *)
    servir_arbre "$chemin"
    ;;
esac
