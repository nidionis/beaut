# status.sh - fetch and render the hub inventory.

status_body() {
  local body
  need curl
  need jq
  body="$(curl --noproxy '*' --silent --show-error --fail --max-time 10 \
    "$(api_url "$HUB" "$PORT" /status)")" || die "hub unreachable: $HUB:$PORT"
  jq -e . <<<"$body" >/dev/null || die "invalid hub status response"
  printf '%s\n' "$body"
}

status_table() {
  need jq
  need awk
  status_body |
    jq -r '.workers[] | [.address, (.hash // ""),
      (if .online then "online" else "offline" end),
      (.resources.cpus // 0), (.resources.mem_available_kb // 0),
      (.resources.disk_free_kb // 0), (.resources.load1 // 0),
      (.jobs | length)] | @tsv' |
    awk -F '\t' -f "$BEAUT_ROOT/share/awk/status.awk"
}

status_html() {
  local body table page
  body="$(status_body)" || {
    http_respond "500 Internal Server Error" "text/plain" $'hub status failed\n'
    return
  }
  table="$(jq -r '.workers[] |
    "<tr><td>\(.address)</td><td><code>\(.hash // "-")</code></td>" +
    "<td>\(if .online then "online" else "offline" end)</td>" +
    "<td>\(.resources.cpus // 0)</td><td>\(.resources.mem_available_kb // 0)</td>" +
    "<td>\(.resources.disk_free_kb // 0)</td><td>\(.resources.load1 // 0)</td>" +
    "<td>\(.jobs | length)</td></tr>"' <<<"$body")"
  page="$(render_template "$BEAUT_ROOT/share/page.html" \
    TITLE "beaut" \
    BODY "<table><tr><th>address</th><th>hash</th><th>state</th><th>cpu</th><th>ram KiB</th><th>disk KiB</th><th>load</th><th>jobs</th></tr>$table</table>")"
  http_respond "200 OK" "text/html; charset=utf-8" "$page"
}
