# status.awk - align the worker table. Fields:
# address hash state cpus ram disk load jobs
BEGIN {
  FS = "\t"
  printf "%-16s %-16s %-8s %5s %12s %12s %7s %5s\n",
    "address", "hash", "state", "cpu", "ram KiB", "disk KiB", "load", "jobs"
}
NF >= 8 {
  printf "%-16s %-16s %-8s %5s %12s %12s %7s %5s\n",
    $1, $2, $3, $4, $5, $6, $7, $8
  next
}
{ print }
