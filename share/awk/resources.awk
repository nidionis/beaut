# resources.awk - read key=value lines from `beaut resources --raw` and format them.
BEGIN {
  FS = "="
}

{
  value[$1] = $2
}

END {
  cpus = value["cpus"] + 0
  load = value["load1"] + 0
  mem_total = value["mem_total_kb"] + 0
  mem_free = value["mem_available_kb"] + 0
  disk_total = value["disk_total_kb"] + 0
  disk_free = value["disk_free_kb"] + 0
  uptime = value["uptime_s"] + 0

  printf "%-8s %s\n", "name", value["name"]
  printf "%-8s %s\n", "host", value["host"]
  printf "%-8s %s cores, load %.2f\n", "cpu", cpus, load
  printf "%-8s %s free / %s\n", "memory", size(mem_free), size(mem_total)
  printf "%-8s %s free / %s\n", "disk", size(disk_free), size(disk_total)
  printf "%-8s %s\n", "uptime", duration(uptime)
}

function size(kb) {
  if (kb <= 0)
    return "-"
  if (kb >= 1048576)
    return sprintf("%.1f GiB", kb / 1048576)
  if (kb >= 1024)
    return sprintf("%.0f MiB", kb / 1024)
  return sprintf("%d KiB", kb)
}

function duration(seconds, days, hours, minutes) {
  if (seconds <= 0)
    return "-"
  days = int(seconds / 86400)
  hours = int((seconds % 86400) / 3600)
  minutes = int((seconds % 3600) / 60)
  if (days > 0)
    return sprintf("%dd %dh %dm", days, hours, minutes)
  if (hours > 0)
    return sprintf("%dh %dm", hours, minutes)
  return sprintf("%dm", minutes)
}
