#!/usr/bin/env bash
# dispatch.sh - small method/path route registry for the HTTP handlers.
#
# Routes are registered as data:
#
#   http_route "GET POST" /sessions/:id/status handler_name [arg...]
#
# Patterns use ":" for a named segment and "*" for a trailing remainder.  The
# dispatcher performs the matching and invokes the handler; request handling
# never needs a growing case/if ladder.

declare -ga HTTP_ROUTE_METHODS=()
declare -ga HTTP_ROUTE_PATTERNS=()
declare -ga HTTP_ROUTE_HANDLERS=()
declare -ga HTTP_ROUTE_ARGS=()
declare -gA HTTP_PARAMS=()

http_route() {
  local methods="$1" pattern="$2" handler="$3"; shift 3
  local arg args=""
  for arg in "$@"; do
    args+="${arg}"$'\n'
  done
  HTTP_ROUTE_METHODS+=("${methods^^}")
  HTTP_ROUTE_PATTERNS+=("$pattern")
  HTTP_ROUTE_HANDLERS+=("$handler")
  HTTP_ROUTE_ARGS+=("$args")
}

http_route_method_allowed() {
  local methods=" ${1^^} " method="${2^^}"
  [[ "$methods" == *" ANY "* || "$methods" == *" $method "* ]]
}

# Match PATH_ABS against a registered pattern.  On success HTTP_PARAMS holds
# decoded named values plus "rest" for a trailing wildcard.
http_path_match() {
  local pattern="${1:-/}" path="${2:-/}"
  local -a pattern_parts=() path_parts=()
  local i=0 part segment rest
  local -a tail=()

  [[ "$pattern" == "/" ]] && pattern=""
  [[ "$path" == "/" ]] && path=""
  pattern="${pattern#/}"
  path="${path#/}"
  [[ "$pattern" == */ ]] && pattern="${pattern%/}"
  [[ "$path" == */ ]] && path="${path%/}"
  [[ -z "$pattern" ]] || IFS='/' read -r -a pattern_parts <<<"$pattern"
  [[ -z "$path" ]] || IFS='/' read -r -a path_parts <<<"$path"

  HTTP_PARAMS=()
  while (( i < ${#pattern_parts[@]} )); do
    part="${pattern_parts[$i]}"
    if [[ "$part" == "*" ]]; then
      (( i == ${#pattern_parts[@]} - 1 )) || return 1
      rest=""
      if (( i < ${#path_parts[@]} )); then
        tail=("${path_parts[@]:i}")
        rest="$(IFS=/; printf '%s' "${tail[*]}")"
      fi
      HTTP_PARAMS[rest]="$rest"
      return 0
    fi
    (( i < ${#path_parts[@]} )) || return 1
    segment="${path_parts[$i]}"
    if [[ "$part" == :* ]]; then
      HTTP_PARAMS["${part#:}"]="$(http_url_decode "$segment")"
    elif [[ "$part" != "$segment" ]]; then
      return 1
    fi
    i=$((i + 1))
  done
  (( i == ${#path_parts[@]} ))
}

http_param() {
  printf '%s' "${HTTP_PARAMS[${1:-}]:-}"
}

# Return 0 when a route handled the request, 1 when no path matched.  A path
# that matches but not the method gets a uniform 405.
http_dispatch() {
  local i saw_path=0
  local -a args=()
  for i in "${!HTTP_ROUTE_PATTERNS[@]}"; do
    http_path_match "${HTTP_ROUTE_PATTERNS[$i]}" "${HTTP_PATH_ABS:-/}" || continue
    saw_path=1
    http_route_method_allowed "${HTTP_ROUTE_METHODS[$i]}" "${HTTP_METHOD:-GET}" || continue
    args=()
    if [[ -n "${HTTP_ROUTE_ARGS[$i]}" ]]; then
      mapfile -t args <<<"${HTTP_ROUTE_ARGS[$i]}"
    fi
    "${HTTP_ROUTE_HANDLERS[$i]}" "${args[@]}"
    return 0
  done
  if (( saw_path )); then
    http_respond_error "$BEAUT_HTTP_METHOD_NOT_ALLOWED" "$BEAUT_MSG_METHOD_NOT_ALLOWED"
    return 0
  fi
  return 1
}
