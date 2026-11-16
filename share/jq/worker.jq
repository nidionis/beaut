# worker.jq - turn one worker /info body into an inventory row.
{name:$name,host:$host,port:$port,via:$via,online:true,last_seen:$seen,
 cpus:.cpus,
 load:.load,
 mem_total_kb:.mem_total_kb,
 mem_available_kb:.mem_available_kb,
 disk_total_kb:.disk_total_kb,
 disk_free_kb:.disk_free_kb,
 uptime_s:.uptime_s}
