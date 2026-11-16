# site.sh - serve the site/ folder tree.
#
# A request path maps to an extensionless script under SITE_DIR:
#   /hello/world -> $SITE_DIR/hello/world
# Files with an extension are data and are never routed. The route script is
# sourced in the HTTP handler. It may call http_respond(), http_not_found() or
# html_page().

site_file() {
  local path="${1#/}" file
  [[ -n "$path" ]] || return 1
  [[ "$path" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*(/[A-Za-z0-9_][A-Za-z0-9_-]*)*$ ]] || return 1
  file="$SITE_DIR/$path"
  [[ -f "$file" && -r "$file" ]] || return 1
  printf '%s\n' "$file"
}

serve_site() {
  local path="$1" file
  if ! file="$(site_file "$path")"; then
    http_not_found
    return
  fi

  SITE_PATH="$path"
  SITE_FILE="$file"
  # shellcheck source=/dev/null
  . "$file"
  if [[ "${HTTP_SENT:-no}" != yes ]]; then
    http_respond "500 Internal Server Error" "text/plain" $'site script sent no response\n'
  fi
}
