# status-table.jq - render the hub inventory as a TSV table.
def gb:
  if . == null then "-"
  else (((. / 1048576) * 10 | floor) / 10 | tostring) + "G" end;

"hub  \(.hub)  \(.now)",
(["NAME","VIA","STATE","CPU","LOAD","MEM","DISK"] | @tsv),
(.workers[] | [
  .name,
  (.via // "-"),
  (if .online then "up" else "down" end),
  (if .cpus == null then "-" else (.cpus | tostring) end),
  (if .load == null then "-" else (.load | tostring) end),
  ((.mem_available_kb | gb) + "/" + (.mem_total_kb | gb)),
  ((.disk_free_kb | gb) + "/" + (.disk_total_kb | gb))
] | @tsv)
