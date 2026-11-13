#!/usr/bin/env bash
# config.sh - load protected defaults, then the operator config.
# Sourced after common.sh.

# Print the host part of an http(s) URL, without scheme, port or path.
beaut_url_host() {
  local host="${1:-}"
  host="${host#*://}"
  host="${host%%/*}"
  if [[ "$host" == \[*\]* ]]; then
    host="${host#\[}"
    host="${host%%\]*}"
  else
    host="${host%%:*}"
  fi
  printf '%s' "$host"
}

beaut_load_config() {
  BEAUT_ROOT="${BEAUT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

  if [[ -z "${BEAUT_DEFAULTS_LOADED:-}" ]]; then
    BEAUT_DEFAULTS="${BEAUT_DEFAULTS:-${BEAUT_ROOT}/etc/beaut.defaults.conf}"
    [[ -f "$BEAUT_DEFAULTS" ]] || beaut_die "protected defaults not found: $BEAUT_DEFAULTS"
    # shellcheck disable=SC1090
    . "$BEAUT_DEFAULTS"
    BEAUT_DEFAULTS_LOADED=1
  fi

  BEAUT_CONFIG="${BEAUT_CONFIG:-${BEAUT_ROOT}/beaut.conf}"

  # Operator config is trusted shell code.  It is loaded after the protected
  # defaults, so a plain assignment here overrides a default cleanly.
  # shellcheck disable=SC1090
  . "$BEAUT_CONFIG"

  # Derived values belong here, not in the protected defaults file: they depend
  # on the role and on operator overrides.
  : "${BEAUT_NODE_NAME:=$BEAUT_HUB_NAME}"
  : "${BEAUT_PUBLIC_URL:=$BEAUT_HUB_URL}"
  : "${BEAUT_ROUTER_DIR:=$BEAUT_STATE_DIR/run/router}"

  BEAUT_HUB_URL="${BEAUT_HUB_URL%/}"
  BEAUT_PUBLIC_URL="${BEAUT_PUBLIC_URL%/}"
  if [[ -z "${BEAUT_WORKER_ADVERTISE:-}" ]]; then
    read -r BEAUT_WORKER_ADVERTISE _ < <(hostname -I 2>/dev/null || true)
  fi
  : "${BEAUT_WORKER_ADVERTISE:=127.0.0.1}"

  export BEAUT_ROOT BEAUT_CONFIG BEAUT_DEFAULTS BEAUT_NAME BEAUT_VERSION
  export BEAUT_USER BEAUT_GROUP BEAUT_HOME
  export BEAUT_STATE_DIR BEAUT_STORE_DIR BEAUT_LOG_DIR BEAUT_WWW_DIR
  export BEAUT_HUB_NAME BEAUT_WORKER_NAME BEAUT_NODE_NAME
  export BEAUT_HUB_URL BEAUT_HUB_PORT BEAUT_HUB_BIND BEAUT_PUBLIC_URL
  export BEAUT_HUB_ADVERTISE
  export BEAUT_WORKER_PORT BEAUT_WORKER_BIND BEAUT_WORKER_ADVERTISE
  export BEAUT_DOCKER BEAUT_ROUTER_DIR
}

beaut_config_show() {
  local name
  for name in \
    BEAUT_NAME BEAUT_VERSION BEAUT_USER BEAUT_GROUP BEAUT_HOME \
    BEAUT_STATE_DIR BEAUT_STORE_DIR BEAUT_LOG_DIR \
    BEAUT_HUB_NAME BEAUT_WORKER_NAME BEAUT_HUB_BIND BEAUT_HUB_PORT \
    BEAUT_HUB_URL BEAUT_HUB_DOMAIN BEAUT_API_TIMEOUT \
    BEAUT_API_DOWNLOAD_TIMEOUT BEAUT_WORKER_BIND BEAUT_WORKER_PORT \
    BEAUT_WORKER_ADVERTISE BEAUT_WORKER_CPUS BEAUT_WORKER_MEMORY_MB \
    BEAUT_WORKER_DISK_MB BEAUT_WORKER_TAGS BEAUT_WORKER_MAX_SESSIONS \
    BEAUT_MIN_COPIES BEAUT_STRICT_COPIES BEAUT_DOCKER; do
    printf '%s=%s\n' "$name" "${!name:-}"
  done
  printf 'BEAUT_WORKERS=%s\n' "${#BEAUT_WORKERS[@]}"
  printf 'BEAUT_ROUTES=%s\n' "${#BEAUT_ROUTES[@]}"
}

beaut_worker_resource_names() {
  printf '%s\n' BEAUT_WORKER_CPUS BEAUT_WORKER_MEMORY_MB BEAUT_WORKER_DISK_MB \
    BEAUT_WORKER_TAGS BEAUT_WORKER_MAX_SESSIONS
}

beaut_worker_resources_show() {
  local name
  while IFS= read -r name; do
    printf '%s=%q\n' "$name" "${!name:-}"
  done < <(beaut_worker_resource_names)
}

# Replace the five resource assignments in an existing operator config.
beaut_worker_resources_write() {
  local tmp="$1"; shift
  local name line
  local -a keep=()
  while IFS= read -r line; do
    keep+=("$line")
  done < "$BEAUT_CONFIG"
  {
    if (( ${#keep[@]} > 0 )); then
      for line in "${keep[@]}"; do
        case "$line" in
          BEAUT_WORKER_CPUS=*|BEAUT_WORKER_MEMORY_MB=*|BEAUT_WORKER_DISK_MB=*|\
          BEAUT_WORKER_TAGS=*|BEAUT_WORKER_MAX_SESSIONS=*) continue ;;
        esac
        printf '%s\n' "$line"
      done
    fi
    printf '\n# worker resources (written by beaut worker resources)\n'
    for name in "$@"; do
      printf '%s\n' "$name"
    done
  } > "$tmp"
}

