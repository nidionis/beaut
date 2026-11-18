# router.sh - resolve and run scripts from the site/ and work/ trees.
#
# A route is a file that is sourced in the HTTP handler. It may send any HTTP
# response and may call any loaded function. If it sends nothing, the router
# turns that into a 500 so a broken route never hangs a client.

# route_clean PATH - normalize one URL path or fail. The path is relative to a
# route tree and never contains "..", hidden components or duplicate slashes.
route_clean() {
  local path="${1#/}"
  [[ -n "$path" ]] || path="index"
  [[ "$path" != *..* ]] || return 1
  [[ "$path" != *//* ]] || return 1
  [[ "$path" != .* && "$path" != */.* ]] || return 1
  [[ "$path" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*(/[A-Za-z0-9_][A-Za-z0-9_.-]*)*$ ]] || return 1
  printf '%s\n' "$path"
}

# site_file PATH - resolve a main-port route to a file. Main routes are
# extensionless scripts; data files must be served by an explicit endpoint.
site_file() {
  local path file
  path="$(route_clean "$1")" || return 1
  [[ "${path##*/}" != *.* ]] || return 1
  file="$SITE_DIR/$path"
  [[ -f "$file" && -r "$file" ]] || return 1
  printf '%s\n' "$file"
}

# work_file PATH - resolve a work-port route. The generic entrypoint is
# work/script.sh; an optional work/<hash>/script.sh overrides it for debugging.
work_file() {
  local path file hash
  path="${1#/}"
  path="${path%/}"

  case "$path" in
    ""|work)
      file="$WORK_DIR/script.sh"
      ;;
    work/*)
      hash="${path#work/}"
      is_hash "$hash" || return 1
      file="$WORK_DIR/$hash/script.sh"
      ;;
    *)
      return 1
      ;;
  esac

  [[ -f "$file" && -r "$file" ]] || return 1
  printf '%s\n' "$file"
}

# serve_site PATH - source one main-port route.
serve_site() {
  local path="$1" file
  file="$(site_file "$path")" || {
    http_not_found
    return
  }

  ROUTE_PATH="$path"
  ROUTE_FILE="$file"
  # shellcheck source=/dev/null
  . "$file"
  if [[ "${HTTP_SENT:-no}" != yes ]]; then
    http_respond "500 Internal Server Error" "text/plain" $'route sent no response\n'
  fi
}

# serve_work PATH - source one work-port route.
serve_work() {
  local path="$1" file
  file="$(work_file "$path")" || {
    http_respond "200 OK" "text/x-shellscript" $':\n'
    return
  }

  ROUTE_PATH="$path"
  ROUTE_FILE="$file"
  # shellcheck source=/dev/null
  . "$file"
  if [[ "${HTTP_SENT:-no}" != yes ]]; then
    http_respond "500 Internal Server Error" "text/plain" $'route sent no response\n'
  fi
}
