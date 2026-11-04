#!/usr/bin/env bash
# lib/stats.sh — cluster stats gathering/rendering for the HTTP app. Sourced.
# shellcheck shell=bash
#
# workers.tsv  : name tunnel_port cpu_pct cpu_total mem_free_mib disk_free_gib last_seen
# sessions.tsv : id user worker kind(cmd|vm) cpu mem disk started_ts
#
# Capacity is what workers donated (cpu_total, mem_free_mib, disk_free_gib);
# sessions currently allocated on an *active* worker are subtracted to get the
# free figures. Workers whose last_seen is older than WORKER_STALE_SECONDS are
# counted but excluded from capacity, exactly like the scheduler will do.

[ -n "${BEAUT_STATS_LOADED:-}" ] && return 0
BEAUT_STATS_LOADED=1

# stats_compute — fill the STATS_* globals. One awk pass over workers+sessions.
stats_compute() {
    local cutoff line
    cutoff=$(( $(now) - WORKER_STALE_SECONDS ))
    line=$(awk -F'\t' -v cutoff="$cutoff" -v wf="$(state_path workers.tsv)" '
        FILENAME == wf {
            if (NF == 0 || $1 == "") next
            total++
            if (($7 + 0) < cutoff) { stale++; next }
            active++
            cap_cpu[$1]  = $4 + 0
            cap_mem[$1]  = $5 + 0
            cap_disk[$1] = $6 + 0
            cpu_t  += $4 + 0
            mem_t  += $5 + 0
            disk_t += $6 + 0
            next
        }
        {
            if (NF == 0 || $1 == "") next
            sessions++
            if ($3 in cap_cpu) {
                if (($5 + 0) > 0) cpu_u  += $5 + 0
                if (($6 + 0) > 0) mem_u  += $6 + 0
                if (($7 + 0) > 0) disk_u += $7 + 0
            }
        }
        END {
            cpu_f  = cpu_t  - cpu_u;  if (cpu_f  < 0) cpu_f  = 0
            mem_f  = mem_t  - mem_u;  if (mem_f  < 0) mem_f  = 0
            disk_f = disk_t - disk_u; if (disk_f < 0) disk_f = 0
            printf "%d %d %d %d %d %d %d %d %d %d\n",
                   total, active, stale, cpu_t, cpu_f, mem_t, mem_f,
                   disk_t, disk_f, sessions
        }
    ' "$(state_path workers.tsv)" "$(state_path sessions.tsv)")

    read -r STATS_WORKERS_TOTAL STATS_WORKERS_ACTIVE STATS_WORKERS_STALE \
            STATS_CPU_TOTAL STATS_CPU_FREE STATS_MEM_TOTAL STATS_MEM_FREE \
            STATS_DISK_TOTAL STATS_DISK_FREE STATS_SESSIONS <<< "$line"
    STATS_PENDING=$(awk -F'\t' 'NF && $4 == 0 {n++} END {print n + 0}' "$(state_path users.tsv)")
    STATS_GENERATED=$(date -u +%FT%TZ)
}

# stats_text — plain-text snapshot for GET / and GET /stats.
stats_text() {
    stats_compute
    printf 'beaut — %s\n' "$DOMAIN"
    printf 'workers     %s (%s stale, %s active)\n' \
        "$STATS_WORKERS_TOTAL" "$STATS_WORKERS_STALE" "$STATS_WORKERS_ACTIVE"
    printf 'cpu         %s total / %s free\n' "$STATS_CPU_TOTAL" "$STATS_CPU_FREE"
    printf 'memory      %s MiB total / %s MiB free\n' "$STATS_MEM_TOTAL" "$STATS_MEM_FREE"
    printf 'disk        %s GiB total / %s GiB free\n' "$STATS_DISK_TOTAL" "$STATS_DISK_FREE"
    printf 'sessions    %s active\n' "$STATS_SESSIONS"
    printf 'pending     %s inscription(s)\n' "$STATS_PENDING"
    printf 'generated   %s\n' "$STATS_GENERATED"
}

# stats_json — one-line JSON snapshot for GET /stats.json.
stats_json() {
    stats_compute
    printf '{"domain":"%s","generated":"%s",' "$DOMAIN" "$STATS_GENERATED"
    printf '"workers":{"total":%s,"active":%s,"stale":%s},' \
        "$STATS_WORKERS_TOTAL" "$STATS_WORKERS_ACTIVE" "$STATS_WORKERS_STALE"
    printf '"cpu":{"total":%s,"free":%s},' "$STATS_CPU_TOTAL" "$STATS_CPU_FREE"
    printf '"memory_mib":{"total":%s,"free":%s},' "$STATS_MEM_TOTAL" "$STATS_MEM_FREE"
    printf '"disk_gib":{"total":%s,"free":%s},' "$STATS_DISK_TOTAL" "$STATS_DISK_FREE"
    printf '"sessions":{"active":%s},"pending_users":%s}\n' \
        "$STATS_SESSIONS" "$STATS_PENDING"
}
