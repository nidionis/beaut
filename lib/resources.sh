# resources.sh - probe the local machine and render it as key=value or JSON.

resources_raw() {
  local cpus load mem_total mem_avail disk_total disk_free uptime path

  cpus="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf 0)"
  load="$(awk '{print $1}' /proc/loadavg 2>/dev/null || printf 0)"

  mem_total=0
  mem_avail=0
  if [[ -r /proc/meminfo ]]; then
    read -r mem_total mem_avail < <(
      awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print (t?t:0), (a?a:0)}' /proc/meminfo
    )
  fi

  path="$ROOT"
  [[ -d "$path" ]] || path="."
  disk_total=0
  disk_free=0
  if command -v df >/dev/null 2>&1; then
    read -r disk_total disk_free < <(df -Pk -- "$path" 2>/dev/null | awk 'NR==2{print $2+0, $4+0}')
  fi

  uptime=0
  if [[ -r /proc/uptime ]]; then
    read -r uptime _ < /proc/uptime || true
    uptime="${uptime%%.*}"
  fi
  is_uint "$uptime" || uptime=0

  printf 'name=%s\n' "$WORKER_NAME"
  printf 'host=%s\n' "$WORKER_HOST"
  printf 'cpus=%s\n' "$cpus"
  printf 'load1=%s\n' "$load"
  printf 'mem_total_kb=%s\n' "${mem_total:-0}"
  printf 'mem_available_kb=%s\n' "${mem_avail:-0}"
  printf 'disk_total_kb=%s\n' "${disk_total:-0}"
  printf 'disk_free_kb=%s\n' "${disk_free:-0}"
  printf 'uptime_s=%s\n' "$uptime"
}

resources_json() {
  local key val name="" host="" cpus=0 load=0
  local mem_total=0 mem_avail=0 disk_total=0 disk_free=0 uptime=0 port

  need jq

  while IFS='=' read -r key val; do
    case "$key" in
      name) name="$val" ;;
      host) host="$val" ;;
      cpus) cpus="$val" ;;
      load1) load="$val" ;;
      mem_total_kb) mem_total="$val" ;;
      mem_available_kb) mem_avail="$val" ;;
      disk_total_kb) disk_total="$val" ;;
      disk_free_kb) disk_free="$val" ;;
      uptime_s) uptime="$val" ;;
    esac
  done < <(resources_raw)

  is_uint "$cpus" || cpus=0
  is_num "$load" || load=0
  is_uint "$mem_total" || mem_total=0
  is_uint "$mem_avail" || mem_avail=0
  is_uint "$disk_total" || disk_total=0
  is_uint "$disk_free" || disk_free=0
  is_uint "$uptime" || uptime=0
  port="$WORKER_PORT"
  is_uint "$port" || port=8090

  jq -cn \
    --arg name "$name" \
    --arg host "$host" \
    --argjson port "$port" \
    --argjson cpus "$cpus" \
    --argjson load "$load" \
    --argjson mem_total_kb "$mem_total" \
    --argjson mem_available_kb "$mem_avail" \
    --argjson disk_total_kb "$disk_total" \
    --argjson disk_free_kb "$disk_free" \
    --argjson uptime_s "$uptime" \
    '{name:$name,host:$host,port:$port,cpus:$cpus,load:$load,
      mem_total_kb:$mem_total_kb,mem_available_kb:$mem_available_kb,
      disk_total_kb:$disk_total_kb,disk_free_kb:$disk_free_kb,
      uptime_s:$uptime_s}'
}

resources_human() {
  need awk
  [[ -f "$BEAUT_ROOT/share/awk/resources.awk" ]] || die "missing share/awk/resources.awk"
  resources_raw | awk -f "$BEAUT_ROOT/share/awk/resources.awk"
}
