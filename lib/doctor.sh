# doctor.sh - print the effective configuration and check dependencies.

doctor() {
  local cmd missing=0
  printf 'root      %s\n' "$BEAUT_ROOT"
  printf 'config    %s\n' "$BEAUT_CONFIG"
  printf 'node      %s\n' "$BEAUT_ENV"
  printf 'hub       %s:%s\n' "$HUB" "$PORT"
  printf 'work      %s:%s\n' "$HUB" "$WORK_PORT"
  printf 'worker    %s:%s\n' "$NODE_ADDRESS" "$WORKER_PORT"
  printf 'root dir  %s\n' "$ROOT"
  printf 'site      %s\n' "$SITE_DIR"
  for cmd in socat curl jq ssh awk tar ssh-keygen sha256sum; do
    if command -v "$cmd" >/dev/null 2>&1; then
      printf '%-9s ok\n' "$cmd"
    else
      printf '%-9s MISSING\n' "$cmd"
      missing=1
    fi
  done
  if command -v docker >/dev/null 2>&1; then
    printf '%-9s ok\n' docker
  elif [[ "$NODE_ROLE" == worker ]]; then
    printf '%-9s MISSING\n' docker
    missing=1
  else
    printf '%-9s not installed (optional on hub)\n' docker
  fi
  printf 'resources\n'
  resources_json
  return "$missing"
}
