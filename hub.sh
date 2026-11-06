#!/usr/bin/env bash
# hub.sh — serveur de contrôle (orchestrateur / hub) de beaut.
#
# Sous-commandes :
#   init                       initialise l'état
#   register <id> <pubkey> <caps>   enregistre un worker
#   heartbeat <id>             met à jour le dernier heartbeat d'un worker
#   submit <client> <commande>   soumet une tâche, affiche l'identifiant
#   poll <id>                  retourne la prochaine tâche affectée au worker (ou "none")
#   result <id> <task> <statut> <fichier_sortie>   collecte le résultat d'une tâche
#   list                       liste workers et tâches
#   daemon                     boucle de dispatch (assign tasks → workers)
#
# État (TSV + flock + mv atomique, cf. refonte.script) :
#   state/workers.tsv      id \t pubkey \t caps \t last_seen \t status
#   state/tasks.tsv        id \t client \t commande \t status \t created_at
#   state/assignments.tsv  task_id \t worker_id \t assigned_at
#   state/heartbeats/<id>  horodatage
#   state/results/<task>   sortie de la tâche
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/core.sh
. "$ROOT_DIR/lib/core.sh"
load_config "$@"

STATE="$STATE_DIR"
WORKERS="$STATE/workers.tsv"
TASKS="$STATE/tasks.tsv"
ASSIGN="$STATE/assignments.tsv"

cmd="${1:-}"
shift || true

now_ts() { date +%s; }

# ---------- helpers TSV ----------

tsv_append() {
  # tsv_append <file> <field>...
  local file="$1"; shift
  local line
  printf -v line '%s\t' "$@"
  line="${line%$'\t'}"
  printf '%s\n' "$line" >> "$file"
}

tsv_find() {
  # tsv_find <file> <match_col> <match_val>  → affiche la ligne complète (1re correspondance)
  local file="$1" col="$2" val="$3"
  awk -F'\t' -v c="$col" -v v="$val" 'NR==1 || $c==v {if($c==v){print; exit}}' "$file"
}

tsv_field() {
  # tsv_field <line> <col>
  awk -F'\t' -v c="$2" '{print $c}' <<<"$1"
}

tsv_update_all() {
  # tsv_update_all <file> <set_col> <set_val> <match_col> <match_val>
  # remplace set_col par set_val sur toutes les lignes où match_col==match_val
  local file="$1" set_col="$2" set_val="$3" match_col="$4" match_val="$5"
  local tmp
  tmp="$(mktemp)"
  awk -F'\t' -v sc="$set_col" -v sv="$set_val" -v mc="$match_col" -v mv="$match_val" \
    'BEGIN{OFS="\t"} $mc==mv{$sc=sv} {print}' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# ---------- init ----------

cmd_init() {
  state_init
  log info "état initialisé dans $STATE"
}

# ---------- register ----------

cmd_register() {
  local wid="$1" pubkey="$2" caps="${3:-}"
  [[ -n "$wid" ]] || { log error "register: id manquant"; exit 2; }
  local ts; ts=$(now_ts)
  with_lock "$STATE/workers.lock" bash -c '
    file="$0"; wid="$1"; pubkey="$2"; caps="$3"; ts="$4"
    # si le worker existe déjà, on met à jour ; sinon on ajoute
    if grep -q "^'"$wid"'\b" "$file" 2>/dev/null; then
      awk -F"\t" -v w="$wid" -v p="$pubkey" -v c="$caps" -v t="$ts" \
        "BEGIN{OFS=\"\t\"} \$1==w{\$2=p;\$3=c;\$5=\"alive\"} {print}" "$file" > "$file.tmp"
      mv "$file.tmp" "$file"
    else
      printf "%s\t%s\t%s\t%s\talive\n" "$wid" "$pubkey" "$caps" "$ts" >> "$file"
    fi
  ' "$WORKERS" "$wid" "$pubkey" "$caps" "$ts"
  echo "$ts" > "$STATE/heartbeats/$wid"
  log info "worker enregistré: $wid (caps=$caps)"
}

# ---------- heartbeat ----------

cmd_heartbeat() {
  local wid="$1"
  [[ -n "$wid" ]] || { log error "heartbeat: id manquant"; exit 2; }
  local ts; ts=$(now_ts)
  with_lock "$STATE/workers.lock" bash -c '
    file="$0"; wid="$1"; ts="$2"
    awk -F"\t" -v w="$wid" -v t="$ts" "BEGIN{OFS=\"\t\"} \$1==w{\$4=t;\$5=\"alive\"} {print}" "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
  ' "$WORKERS" "$wid" "$ts"
  echo "$ts" > "$STATE/heartbeats/$wid"
  log debug "heartbeat: $wid @ $ts"
}

# ---------- submit ----------

cmd_submit() {
  local client="$1"; shift
  local command="$*"
  [[ -n "$command" ]] || { log error "submit: commande manquante"; exit 2; }
  local task_id; task_id=$(uid)
  local ts; ts=$(now_ts)
  with_lock "$STATE/tasks.lock" bash -c '
    file="$0"; tid="$1"; client="$2"; cmd="$3"; ts="$4"
    printf "%s\t%s\t%s\tpending\t%s\n" "$tid" "$client" "$cmd" "$ts" >> "$file"
  ' "$TASKS" "$task_id" "$client" "$command" "$ts"
  echo "$task_id"
  log info "tâche soumise: $task_id par $client"
}

# ---------- daemon (dispatch) ----------

mark_stale() {
  local now cutoff
  now=$(now_ts)
  cutoff=$(( now - WORKER_STALE_SECONDS ))
  with_lock "$STATE/workers.lock" bash -c '
    file="$0"; cutoff="$1"
    awk -F"\t" -v c="$cutoff" "BEGIN{OFS=\"\t\"} \$4+0 < c+0 {\$5=\"stale\"} {print}" "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
  ' "$WORKERS" "$cutoff"
}

alive_workers() {
  awk -F'\t' '$5=="alive"{print $1}' "$WORKERS"
}

pending_tasks() {
  awk -F'\t' '$4=="pending"{print $1"\t"$2"\t"$3}' "$TASKS"
}

is_assigned() {
  # is_assigned <task_id>
  grep -q "^$1\b" "$ASSIGN" 2>/dev/null
}

cmd_daemon() {
  state_init
  log info "démarrage du daemon de dispatch (intervalle=${HEARTBEAT_INTERVAL}s)"
  while true; do
    mark_stale
    while IFS=$'\t' read -r tid client command; do
      [[ -z "$tid" ]] && continue
      is_assigned "$tid" && continue
      # premier worker alive disponible (round-robin simplifié)
      local worker=""
      while IFS= read -r w; do
        [[ -n "$w" ]] && { worker="$w"; break; }
      done < <(alive_workers)
      if [[ -z "$worker" ]]; then
        log warn "aucun worker alive pour la tâche $tid"
        continue
      fi
      local ats; ats=$(now_ts)
      with_lock "$STATE/assignments.lock" bash -c '
        file="$0"; tid="$1"; w="$2"; ats="$3"
        printf "%s\t%s\t%s\n" "$tid" "$w" "$ats" >> "$file"
      ' "$ASSIGN" "$tid" "$worker" "$ats"
      with_lock "$STATE/tasks.lock" bash -c '
        file="$0"; tid="$1"
        awk -F"\t" -v t="$tid" "BEGIN{OFS=\"\t\"} \$1==t{\$4=\"assigned\"} {print}" "$file" > "$file.tmp"
        mv "$file.tmp" "$file"
      ' "$TASKS" "$tid"
      log info "tâche $tid affectée au worker $worker"
    done < <(pending_tasks)
    sleep "$HEARTBEAT_INTERVAL"
  done
}

# ---------- poll ----------

cmd_poll() {
  local wid="$1"
  [[ -n "$wid" ]] || { log error "poll: id manquant"; exit 2; }
  # tâche affectée à ce worker et pas encore terminée
  local line
  line=$(awk -F'\t' -v w="$wid" '$2==w{print $1}' "$ASSIGN" | head -n1)
  if [[ -z "$line" ]]; then
    echo "none"
    return 0
  fi
  local tid="$line"
  # vérifier que la tâche n'est pas déjà done/failed
  local tline status
  tline=$(tsv_find "$TASKS" 1 "$tid")
  status=$(tsv_field "$tline" 4)
  if [[ "$status" == "done" || "$status" == "failed" ]]; then
    echo "none"
    return 0
  fi
  local command client
  client=$(tsv_field "$tline" 2)
  command=$(tsv_field "$tline" 3)
  # résultat : task_id \t client \t commande
  printf '%s\t%s\t%s\n' "$tid" "$client" "$command"
}

# ---------- result ----------

cmd_result() {
  local wid="$1" tid="$2" status="${3:-done}" output_spec="${4:-}"
  [[ -n "$tid" ]] || { log error "result: task manquant"; exit 2; }
  # enregistrer le résultat : fichier, "-" (stdin) ou rien (vide)
  if [[ -n "$output_spec" && "$output_spec" != "-" ]]; then
    [[ -f "$output_spec" ]] || { log error "result: fichier introuvable $output_spec"; exit 2; }
    cp "$output_spec" "$STATE/results/$tid"
  elif [[ -t 0 ]]; then
    : # pas d'entrée, résultat vide
  else
    cat > "$STATE/results/$tid"
  fi
  with_lock "$STATE/tasks.lock" bash -c '
    file="$0"; tid="$1"; st="$2"
    awk -F"\t" -v t="$tid" -v s="$st" "BEGIN{OFS=\"\t\"} \$1==t{\$4=s} {print}" "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
  ' "$TASKS" "$tid" "$status"
  # libérer l'assignation
  if [[ -f "$ASSIGN" ]]; then
    awk -F'\t' -v t="$tid" '$1!=t' "$ASSIGN" > "$ASSIGN.tmp" && mv "$ASSIGN.tmp" "$ASSIGN"
  fi
  log info "résultat tâche $tid par $wid → $status"
}

# ---------- list ----------

cmd_list() {
  echo "=== workers ==="
  column -t -s $'\t' "$WORKERS" 2>/dev/null || cat "$WORKERS"
  echo
  echo "=== tâches ==="
  column -t -s $'\t' "$TASKS" 2>/dev/null || cat "$TASKS"
}

# ---------- dispatcher ----------

case "$cmd" in
  init)          cmd_init ;;
  register)      cmd_register "$@" ;;
  heartbeat)     cmd_heartbeat "$1" ;;
  submit)        cmd_submit "$@" ;;
  daemon)        cmd_daemon ;;
  poll)          cmd_poll "$1" ;;
  result)        cmd_result "$1" "$2" "${3:-done}" "${4:-}" ;;
  list)          cmd_list ;;
  *)             echo "usage: hub.sh {init|register|heartbeat|submit|poll|result|list|daemon} ..." >&2; exit 2 ;;
esac
