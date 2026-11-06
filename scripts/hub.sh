#!/usr/bin/env bash
# hub.sh — serveur de contrôle (orchestrateur).
# Sous-commandes : init register heartbeat submit daemon poll result list
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
# shellcheck source=lib/core.sh
. "$SCRIPTS_DIR/lib/core.sh"
load_config "$@"

STATE="$STATE_DIR"
WORKERS="$STATE/workers.tsv"
TASKS="$STATE/tasks.tsv"
ASSIGN="$STATE/assignments.tsv"

cmd="${1:-}"
shift || true
now_ts() { date +%s; }

tsv_append() {
  local file="$1"; shift
  local line; printf -v line '%s\t' "$@"; line="${line%$'\t'}"
  printf '%s\n' "$line" >> "$file"
}

tsv_find() {
  awk -F'\t' -v c="$2" -v v="$3" '$c==v{print; exit}' "$1"
}

tsv_field() { awk -F'\t' -v c="$2" '{print $c}' <<<"$1"; }

cmd_init() { state_init; log info "état initialisé dans $STATE"; }

cmd_register() {
  local wid="$1" pubkey="$2" caps="${3:-}"
  [[ -n "$wid" ]] || { log error "register: id manquant"; exit 2; }
  local ts; ts=$(now_ts)
  with_lock "$STATE/workers.lock" bash -c '
    file="$0"; wid="$1"; p="$2"; c="$3"; t="$4"
    if grep -q "^'"$wid"'\b" "$file" 2>/dev/null; then
      awk -F"\t" -v w="$wid" -v p="$p" -v c="$c" -v t="$t" "BEGIN{OFS=\"\t\"} \$1==w{\$2=p;\$3=c;\$5=\"alive\"} {print}" "$file" > "$file.tmp"; mv "$file.tmp" "$file"
    else
      printf "%s\t%s\t%s\t%s\talive\n" "$wid" "$p" "$c" "$t" >> "$file"
    fi
  ' "$WORKERS" "$wid" "$pubkey" "$caps" "$ts"
  echo "$ts" > "$STATE/heartbeats/$wid"
  log info "worker enregistré: $wid"
}

cmd_heartbeat() {
  local wid="$1"; [[ -n "$wid" ]] || { log error "heartbeat: id manquant"; exit 2; }
  local ts; ts=$(now_ts)
  with_lock "$STATE/workers.lock" bash -c '
    file="$0"; wid="$1"; t="$2"
    awk -F"\t" -v w="$wid" -v t="$t" "BEGIN{OFS=\"\t\"} \$1==w{\$4=t;\$5=\"alive\"} {print}" "$file" > "$file.tmp"; mv "$file.tmp" "$file"
  ' "$WORKERS" "$wid" "$ts"
  echo "$ts" > "$STATE/heartbeats/$wid"
}

cmd_submit() {
  local client="$1"; shift; local command="$*"
  [[ -n "$command" ]] || { log error "submit: commande manquante"; exit 2; }
  local task_id; task_id=$(uid); local ts; ts=$(now_ts)
  with_lock "$STATE/tasks.lock" bash -c '
    file="$0"; tid="$1"; client="$2"; cmd="$3"; t="$4"
    printf "%s\t%s\t%s\tpending\t%s\n" "$tid" "$client" "$cmd" "$t" >> "$file"
  ' "$TASKS" "$task_id" "$client" "$command" "$ts"
  echo "$task_id"
  log info "tâche soumise: $task_id"
}

mark_stale() {
  local now cutoff; now=$(now_ts); cutoff=$(( now - WORKER_STALE_SECONDS ))
  with_lock "$STATE/workers.lock" bash -c '
    file="$0"; c="$1"
    awk -F"\t" -v c="$c" "BEGIN{OFS=\"\t\"} \$4+0 < c+0 {\$5=\"stale\"} {print}" "$file" > "$file.tmp"; mv "$file.tmp" "$file"
  ' "$WORKERS" "$cutoff"
}

alive_workers() { awk -F'\t' '$5=="alive"{print $1}' "$WORKERS"; }
pending_tasks() { awk -F'\t' '$4=="pending"{print $1"\t"$2"\t"$3}' "$TASKS"; }
is_assigned() { grep -q "^$1\b" "$ASSIGN" 2>/dev/null; }

cmd_daemon() {
  state_init
  log info "daemon dispatch lancé (intervalle=${HEARTBEAT_INTERVAL}s)"
  while true; do
    mark_stale
    while IFS=$'\t' read -r tid client command; do
      [[ -z "$tid" ]] && continue
      is_assigned "$tid" && continue
      local worker=""
      while IFS= read -r w; do [[ -n "$w" ]] && { worker="$w"; break; }; done < <(alive_workers)
      [[ -z "$worker" ]] && { log warn "aucun worker alive pour $tid"; continue; }
      local ats; ats=$(now_ts)
      with_lock "$STATE/assignments.lock" bash -c '
        file="$0"; tid="$1"; w="$2"; t="$3"; printf "%s\t%s\t%s\n" "$tid" "$w" "$t" >> "$file"
      ' "$ASSIGN" "$tid" "$worker" "$ats"
      with_lock "$STATE/tasks.lock" bash -c '
        file="$0"; tid="$1"; awk -F"\t" -v t="$tid" "BEGIN{OFS=\"\t\"} \$1==t{\$4=\"assigned\"} {print}" "$file" > "$file.tmp"; mv "$file.tmp" "$file"
      ' "$TASKS" "$tid"
      log info "tâche $tid → $worker"
    done < <(pending_tasks)
    sleep "$HEARTBEAT_INTERVAL"
  done
}

cmd_poll() {
  local wid="$1"; [[ -n "$wid" ]] || { log error "poll: id manquant"; exit 2; }
  local tid; tid=$(awk -F'\t' -v w="$wid" '$2==w{print $1; exit}' "$ASSIGN")
  [[ -z "$tid" ]] && { echo "none"; return 0; }
  local tline status; tline=$(tsv_find "$TASKS" 1 "$tid"); status=$(tsv_field "$tline" 4)
  [[ "$status" == "done" || "$status" == "failed" ]] && { echo "none"; return 0; }
  local client command; client=$(tsv_field "$tline" 2); command=$(tsv_field "$tline" 3)
  printf '%s\t%s\t%s\n' "$tid" "$client" "$command"
}

cmd_result() {
  local wid="$1" tid="$2" status="${3:-done}" output_spec="${4:-}"
  [[ -n "$tid" ]] || { log error "result: task manquant"; exit 2; }
  if [[ -n "$output_spec" && "$output_spec" != "-" ]]; then
    [[ -f "$output_spec" ]] || { log error "result: fichier introuvable"; exit 2; }
    cp "$output_spec" "$STATE/results/$tid"
  elif [[ ! -t 0 ]]; then cat > "$STATE/results/$tid"; fi
  with_lock "$STATE/tasks.lock" bash -c '
    file="$0"; tid="$1"; st="$2"; awk -F"\t" -v t="$tid" -v s="$st" "BEGIN{OFS=\"\t\"} \$1==t{\$4=s} {print}" "$file" > "$file.tmp"; mv "$file.tmp" "$file"
  ' "$TASKS" "$tid" "$status"
  if [[ -f "$ASSIGN" ]]; then awk -F'\t' -v t="$tid" '$1!=t' "$ASSIGN" > "$ASSIGN.tmp" && mv "$ASSIGN.tmp" "$ASSIGN"; fi
  log info "résultat $tid par $wid → $status"
}

cmd_list() {
  echo "=== workers ==="; column -t -s $'\t' "$WORKERS" 2>/dev/null || cat "$WORKERS"
  echo; echo "=== tâches ==="; column -t -s $'\t' "$TASKS" 2>/dev/null || cat "$TASKS"
}

case "$cmd" in
  init) cmd_init ;;
  register) cmd_register "$@" ;;
  heartbeat) cmd_heartbeat "$1" ;;
  submit) cmd_submit "$@" ;;
  daemon) cmd_daemon ;;
  poll) cmd_poll "$1" ;;
  result) cmd_result "$1" "$2" "${3:-done}" "${4:-}" ;;
  list) cmd_list ;;
  *) echo "usage: hub.sh {init|register|heartbeat|submit|daemon|poll|result|list} ..." >&2; exit 2 ;;
esac
