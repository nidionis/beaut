# resources.awk - render key=value resource output as a small table.
BEGIN {
  FS = "="
  label["hash"] = "hash"
  label["address"] = "address"
  label["cpus"] = "cpus"
  label["load1"] = "load1"
  label["mem_total_kb"] = "memory total KiB"
  label["mem_available_kb"] = "memory free KiB"
  label["disk_total_kb"] = "disk total KiB"
  label["disk_free_kb"] = "disk free KiB"
  label["uptime_s"] = "uptime seconds"
}
{
  key = $1
  value = substr($0, index($0, "=") + 1)
  printf "%-20s %s\n", (key in label ? label[key] : key), value
}
