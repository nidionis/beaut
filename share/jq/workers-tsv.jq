# workers-tsv.jq - flatten the hub inventory into the cached TSV table.
.workers[] | [
  .name,
  (.via // ""),
  ((.online // false) | tostring),
  (.cpus // ""),
  (.load // ""),
  (.mem_available_kb // ""),
  (.mem_total_kb // ""),
  (.disk_free_kb // ""),
  (.disk_total_kb // ""),
  (.last_seen // "")
] | @tsv
