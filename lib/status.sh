# status.sh - fetch the public hub inventory and render it.

status_body() {
  local body
  need curl
  need jq
  [[ -n "$PUBLIC_URL" ]] || die "PUBLIC_URL is empty; set it in $BEAUT_CONFIG"

  body="$(curl -fsS --connect-timeout 2 --max-time 6 "${PUBLIC_URL%/}/status" 2>/dev/null)" ||
    die "hub unreachable: $PUBLIC_URL"
  jq -e . >/dev/null 2>&1 <<<"$body" ||
    die "invalid hub response: $PUBLIC_URL"
  printf '%s\n' "$body"
}

status_table() {
  need awk
  status_body |
    jq -r -f "$BEAUT_ROOT/share/jq/status-table.jq" |
    awk -F '\t' -f "$BEAUT_ROOT/share/awk/status.awk"
}
