#!/usr/bin/env bash
# http_handler.sh — gestionnaire HTTP côté SERVEUR.
# Le serveur n'exécute rien : il sert des scripts/tokens et valide les rendus.
# Routes :
#   GET  /work          -> cree un token, assigne une tache, renvoie le token
#   GET  /work/<token>  -> renvoie la commande associee au token
#   POST /done/<token>  -> enregistre le resultat lie au token
#   POST /get           -> requete dataset sur mesure (cle=val&cle=val)
#   GET  /<fichier>     -> lecture seule depuis HTTP_FILE_ROOT
set -uo pipefail

SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SDIR/lib/core.sh"
load_config

STATE_DIR="${STATE_DIR:-$DIR/state}"
DB="$STATE_DIR/db.tsv"
mkdir -p "$STATE_DIR"
[[ -f "$DB" ]] || : > "$DB"

# --- Reponse HTTP minimaliste ---------------------------------------------
http_response() {
  local code="${1:-200}"; shift
  local bod="$*"
  local len; len="${#bod}"
  printf 'HTTP/1.1 %s OK\r\nContent-Length: %s\r\nContent-Type: text/plain\r\n\r\n%s' "$code" "$len" "$bod"
}

# --- Archivage journalier d'un resultat ------------------------------------
archive_daily() {
  local token="$1" result="$2"
  local day; day="$(date +%F)"
  local ad="$STATE_DIR/archive/$day"
  mkdir -p "$ad"

  local total_kb avail_kb hist_max
  total_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  avail_kb="$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  hist_max=$(( total_kb / HIST_MEM_MAX_RATIO ))
  if [[ "$avail_kb" -le "$hist_max" ]]; then
    log warn "archive ignoree : RAM dispo=${avail_kb}KB <= HIST_MEM_MAX=${hist_max}KB"
    return 0
  fi

  local ts; ts="$(date +%s)"
  local node; node="$(hostname 2>/dev/null || echo unknown)"
  printf 'archive\t%s\t%s\t%s\t%s\t%s\t%s\n' "$day" "$token" "$node" "$result" "$ts" "" "" >> "$DB"
  printf '%s\t%s\t%s\t%s\n' "$token" "$node" "$result" "$ts" >> "$ad/results.tsv"
}

# --- Lecture de la requete HTTP -------------------------------------------
# 1. Premiere ligne : METHOD /path HTTP/1.1
IFS= read -r -t 5 first_line || exit 0
method="${first_line%% *}"
path="${first_line#* }"; path="${path%% *}"
path="${path#/}"
path="${path%%\?*}"

# 2. On ignore les en-tetes, on lit le corps brut (POST)
body="$(cat)"

# --- Extraction d'un parametre dans le corps (cle=val&cle=val) ------------
get_param() {
  local key="$1"
  printf '%s' "$body" | awk -F'[&?]' -v k="$key" '{
    for (i=1;i<=NF;i++) {
      split($i,a,"=");
      if (a[1]==k) { print a[2]; exit }
    }
  }'
}

# --- Routage --------------------------------------------------------------
case "$path" in
  work)
    # Creer un nouveau token et associer une tache par defaut
    token="$(uid | tr -d '.')"
    ts="$(date +%s)"
    printf 'token\t%s\techo hello-world\tpending\t%s\t\t\t\n' "$token" "$ts" >> "$DB"
    http_response 200 "$token"
    ;;
  work/*)
    token="${path#work/}"
    line="$(tsv_find "$DB" 2 "$token")"
    if [[ -z "$line" ]]; then
      http_response 404 "${ERR404:-404}"
    else
      type="$(printf '%s' "$line" | cut -f1)"
      status="$(printf '%s' "$line" | cut -f4)"
      command="$(printf '%s' "$line" | cut -f3)"
      if [[ "$type" != "token" ]]; then
        http_response 404 "${ERR404:-404}"
      elif [[ "$status" == "pending" || "$status" == "" ]]; then
        http_response 200 "$command"
      else
        http_response 410 "token expire ou utilise ($status)"
      fi
    fi
    ;;
  done/*)
    token="${path#done/}"
    if [[ -z "$token" ]]; then
      http_response 400 "token manquant"
    else
      archive_daily "$token" "$body"
      tsv_update "$DB" 4 "done" 2 "$token" 2>/dev/null || true
      http_response 200 "confirme: $token"
    fi
    ;;
  get)
    # Requete dataset sur mesure : cle=val dans le corps
    req_token="$(get_param token)"
    dataset="$(get_param dataset)"
    if [[ -z "$req_token" ]]; then
      http_response 400 "token manquant"
    elif [[ -z "$dataset" ]]; then
      http_response 400 "dataset manquant"
    else
      line="$(tsv_find "$DB" 1 "$req_token")"
      if [[ -z "$line" ]]; then
        http_response 403 "token inconnu"
      else
        http_response 200 "dataset $dataset alloue au token $req_token"
      fi
    fi
    ;;
  *)
    # Lecture seule de fichier partage
    if [[ -n "${HTTP_FILE_ROOT:-}" && -f "$HTTP_FILE_ROOT/$path" ]]; then
      cat "$HTTP_FILE_ROOT/$path"
      exit 0
    fi
    http_response 404 "${ERR404:-404}"
    ;;
esac
