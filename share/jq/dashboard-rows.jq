# dashboard-rows.jq - render one HTML table row per worker.
def gb:
  if . == null then "-"
  else (((. / 1048576) * 10 | floor) / 10 | tostring) + " GiB" end;

.workers[] |
"<tr><td>" + (.name | @html) + "</td><td>" + ((.via // "-") | @html) +
"</td><td class=\"" + (if .online then "up" else "down" end) + "\">" +
(if .online then "up" else "down" end) + "</td><td>" +
((.cpus // "-") | tostring) + "</td><td>" + ((.load // "-") | tostring) +
"</td><td>" + (.mem_available_kb | gb) + " / " + (.mem_total_kb | gb) +
"</td><td>" + (.disk_free_kb | gb) + " / " + (.disk_total_kb | gb) +
"</td></tr>"
