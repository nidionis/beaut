#!/usr/bin/env bash
# report.sh - human-readable output for the CLI.
#
# Data collection belongs to api.sh / store.sh / workers.sh / sessions.sh /
# routes.sh.  This file only turns JSON into aligned Bash-built tables, so the
# entry-point script stays free of awk and inline jq filters.

# report_table "ID:71 NAME:24 BYTES:10:r" row1 row2 ...
#
# Column specs are space separated: NAME:WIDTH:ALIGN.  WIDTH may be 0 to size
# from the content; ALIGN is "l" (default) or "r".  Rows are tab-separated.
report_table() {
  local spec="${1:-}"; shift || true
  local -a titles=() widths=() aligns=() rows=("$@")
  local token title width align
  for token in $spec; do
    title="${token%%:*}"
    if [[ "$token" == *:* ]]; then
      token="${token#*:}"
      width="${token%%:*}"
      if [[ "$token" == *:* ]]; then align="${token#*:}"; else align="l"; fi
    else
      width=0
      align="l"
    fi
    [[ "$width" =~ ^[0-9]+$ ]] || width=0
    titles+=("$title")
    widths+=("$width")
    aligns+=("$align")
  done

  local -a fields=()
  local row i cell len
  if (( ${#rows[@]} > 0 )); then
    for row in "${rows[@]}"; do
      IFS=$'\t' read -r -a fields <<<"$row"
      for i in "${!titles[@]}"; do
        cell="${fields[$i]:-}"
        len="${#cell}"
        (( len > widths[i] )) && widths[i]="$len"
      done
    done
  fi

  local line
  line=""
  for i in "${!titles[@]}"; do
    (( i == 0 )) || line+="  "
    if [[ "${aligns[$i]}" == "r" ]]; then
      printf -v cell '%*s' "${widths[$i]}" "${titles[$i]}"
    else
      printf -v cell '%-*s' "${widths[$i]}" "${titles[$i]}"
    fi
    line+="$cell"
  done
  printf '%s\n' "$line"

  line=""
  for i in "${!titles[@]}"; do
    (( i == 0 )) || line+="  "
    printf -v cell '%*s' "${widths[$i]}" ''
    line+="${cell// /-}"
  done
  printf '%s\n' "$line"

  if (( ${#rows[@]} > 0 )); then
    for row in "${rows[@]}"; do
      IFS=$'\t' read -r -a fields <<<"$row"
      line=""
      for i in "${!titles[@]}"; do
        (( i == 0 )) || line+="  "
        cell="${fields[$i]:-}"
        if [[ "${aligns[$i]}" == "r" ]]; then
          printf -v cell '%*s' "${widths[$i]}" "$cell"
        else
          printf -v cell '%-*s' "${widths[$i]}" "$cell"
        fi
        line+="$cell"
      done
      printf '%s\n' "$line"
    done
  fi
}

_report_collect() {
  local json="${1:-}" filter="$2"
  if [[ -z "$json" ]]; then json="$(cat)"; fi
  jq -r "$filter" <<<"$json" 2>/dev/null || true
}

report_workers() {
  local json="${1:-}" row
  local -a rows=()
  while IFS= read -r row; do
    [[ -n "$row" ]] && rows+=("$row")
  done < <(_report_collect "$json" \
    '.[]? | [.name, (.host // ""), ((.port // 0) | tostring),
      (if .online then "yes" else "no" end),
      ((.resources.cpus // "-") | tostring),
      ((.resources.memory_mb // "-") | tostring),
      (.configured.preferred_hub // "")] | @tsv')
  if (( ${#rows[@]} > 0 )); then
    report_table 'NAME:16 HOST:16 PORT:6:r ONLINE:6 CPUS:6:r MEM_MB:8:r HUB' "${rows[@]}"
  else
    report_table 'NAME:16 HOST:16 PORT:6:r ONLINE:6 CPUS:6:r MEM_MB:8:r HUB'
  fi
}

report_sessions() {
  local json="${1:-}" row
  local -a rows=()
  while IFS= read -r row; do
    [[ -n "$row" ]] && rows+=("$row")
  done < <(_report_collect "$json" \
    '.[]? | [.id, .name, (.worker // ""), (.status // ""),
      ((.host_port // 0) | tostring), (.snapshot // "")] | @tsv')
  if (( ${#rows[@]} > 0 )); then
    report_table 'ID:22 NAME:20 WORKER:16 STATUS:10 PORT:7:r SNAPSHOT' "${rows[@]}"
  else
    report_table 'ID:22 NAME:20 WORKER:16 STATUS:10 PORT:7:r SNAPSHOT'
  fi
}

report_packages() {
  local json="${1:-}" row
  local -a rows=()
  while IFS= read -r row; do
    [[ -n "$row" ]] && rows+=("$row")
  done < <(_report_collect "$json" \
    '.[]? | [.id, .name, .kind, (.size | tostring),
      ((.copies | length) | tostring), (.degraded | tostring)] | @tsv')
  if (( ${#rows[@]} > 0 )); then
    report_table 'ID:71 NAME:24 KIND:14 BYTES:10:r COPIES:6:r DEGRADED' "${rows[@]}"
  else
    report_table 'ID:71 NAME:24 KIND:14 BYTES:10:r COPIES:6:r DEGRADED'
  fi
}

report_routes() {
  local json="${1:-}" row
  local -a rows=()
  while IFS= read -r row; do
    [[ -n "$row" ]] && rows+=("$row")
  done < <(_report_collect "$json" \
    '.[]? | [.name, (.host // ""), (.path // ""), (.worker // ""),
      ((.port // 0) | tostring), (.mode // ""),
      (.preferred_hub // ""), ((.listen_port // "") | tostring)] | @tsv')
  if (( ${#rows[@]} > 0 )); then
    report_table 'NAME:18 HOST:26 PATH:12 WORKER:16 PORT:6:r MODE:5 HUB:8 LISTEN' "${rows[@]}"
  else
    report_table 'NAME:18 HOST:26 PATH:12 WORKER:16 PORT:6:r MODE:5 HUB:8 LISTEN'
  fi
}

report_scrub() {
  local json="${1:-}" row
  local -a rows=()
  while IFS= read -r row; do
    [[ -n "$row" ]] && rows+=("$row")
  done < <(_report_collect "$json" \
    '.results[]? | [.id, (if .ok then "ok" else "FAIL" end)] | @tsv')
  if (( ${#rows[@]} > 0 )); then
    report_table 'ID:71 RESULT' "${rows[@]}"
  else
    report_table 'ID:71 RESULT'
  fi
}

report_store_stats() {
  local json="${1:-}" packages objects bytes
  packages="$(jq -r '.packages // 0' <<<"$json" 2>/dev/null || printf '0')"
  objects="$(jq -r '.objects // 0' <<<"$json" 2>/dev/null || printf '0')"
  bytes="$(jq -r '.bytes // 0' <<<"$json" 2>/dev/null || printf '0')"
  printf 'packages: %s  objects: %s  bytes: %s\n' "$packages" "$objects" "$bytes"
}

report_status() {
  local source="$1" health="$2" workers_json="$3" sessions_json="$4"
  local stats_json="$5" routes_json="$6"
  local packages objects bytes routes sessions
  packages="$(jq -r '.packages // 0' <<<"$stats_json" 2>/dev/null || printf '0')"
  objects="$(jq -r '.objects // 0' <<<"$stats_json" 2>/dev/null || printf '0')"
  bytes="$(jq -r '.bytes // 0' <<<"$stats_json" 2>/dev/null || printf '0')"
  routes="$(jq -r 'length' <<<"$routes_json" 2>/dev/null || printf '0')"
  sessions="$(jq -r 'length' <<<"$sessions_json" 2>/dev/null || printf '0')"

  printf 'config: %s\n' "$BEAUT_CONFIG"
  printf 'hub:    %s (%s)\n' "$BEAUT_HUB_NAME" "$BEAUT_HUB_URL"
  printf 'health: %s (%s)\n' "$health" "$source"
  printf 'store:  %s packages, %s objects, %s bytes\n' "$packages" "$objects" "$bytes"
  printf 'counts: %s workers, %s sessions, %s routes\n' \
    "$(jq -r 'length' <<<"$workers_json" 2>/dev/null || printf '0')" \
    "$sessions" "$routes"

  printf '\nworkers:\n'
  report_workers "$workers_json"
  printf '\nsessions:\n'
  report_sessions "$sessions_json"
}

report_doctor_line() {
  printf '%-7s %s\n' "${1:-}" "${2:-}"
}
