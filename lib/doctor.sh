# doctor.sh - print the effective configuration and check dependencies.

doctor() {
  local cmd missing=0
  printf 'root     %s\n' "$BEAUT_ROOT"
  printf 'config   %s\n' "$BEAUT_CONFIG"
  printf 'env      %s\n' "$BEAUT_ENV"
  printf 'public   %s\n' "${PUBLIC_URL:--}"
  printf 'site     %s\n' "$SITE_DIR"
  printf 'worker   %s (%s:%s)\n' "$WORKER_NAME" "$WORKER_HOST" "$WORKER_PORT"
  printf 'state    %s\n' "$STATE_DIR"
  for cmd in socat curl jq ssh awk tar; do
    if command -v "$cmd" >/dev/null 2>&1; then
      printf '%-8s ok\n' "$cmd"
    else
      printf '%-8s MISSING\n' "$cmd"
      missing=1
    fi
  done
  if command -v jq >/dev/null 2>&1; then
    printf 'resources\n'
    resources_json | jq .
  fi
  return "$missing"
}
