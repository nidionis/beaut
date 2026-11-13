#!/usr/bin/env bash
# api.sh - small client for the hub HTTP API.
#
# CLI commands use this first so they work from any machine that can reach the
# hub, not only on the hub host.  The API base always comes from
# BEAUT_HUB_URL; there is no hard-coded address in this file.

beaut_api_base() {
  printf '%s' "${BEAUT_HUB_URL%/}"
}

beaut_api_timeout() {
  printf '%s' "${BEAUT_API_TIMEOUT:-5}"
}

beaut_api_online() {
  local base
  base="$(beaut_api_base)"
  [[ -n "$base" ]] || return 1
  curl -fsS --connect-timeout 2 --max-time 2 "$base/health" >/dev/null 2>&1
}

# beaut_api_request METHOD PATH [BODY_OR_FILE] [OUTPUT]
# BODY_OR_FILE: JSON string, a JSON file, or a file to upload.  A regular file
# is sent as application/octet-stream; a string is sent as application/json.
beaut_api_request() {
  local method="$1" path="$2" body="${3:-}" output="${4:-}"
  local base tmp status
  base="$(beaut_api_base)"
  [[ -n "$base" ]] || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/beaut-api.XXXXXX")" || return 1
  local -a args=(-sS --connect-timeout 2 --max-time "$(beaut_api_timeout)"
    -o "$tmp" -w '%{http_code}' -X "$method")
  if [[ -n "$body" ]]; then
    if [[ -f "$body" ]]; then
      args+=(-H 'Content-Type: application/octet-stream' --data-binary "@$body")
    else
      args+=(-H 'Content-Type: application/json' --data-binary "$body")
    fi
  fi
  if ! status="$(curl "${args[@]}" "${base}${path}" 2>/dev/null)"; then
    rm -f -- "$tmp"
    return 1
  fi
  if [[ -n "$output" ]]; then
    mv -f -- "$tmp" "$output"
  else
    cat -- "$tmp"
  fi
  rm -f -- "$tmp"
  [[ "$status" =~ ^2[0-9][0-9]$ ]]
}

beaut_api_get() {
  beaut_api_request GET "$1" "" "${2:-}"
}

beaut_api_post() {
  beaut_api_request POST "$1" "${2:-}" "${3:-}"
}

beaut_api_put() {
  beaut_api_request PUT "$1" "${2:-}" "${3:-}"
}

beaut_api_delete() {
  beaut_api_request DELETE "$1" "" "${2:-}"
}

beaut_api_download() {
  local path="$1" output="$2" base
  base="$(beaut_api_base)"
  [[ -n "$base" ]] || return 1
  curl -fsS --connect-timeout 3 --max-time "${BEAUT_API_DOWNLOAD_TIMEOUT:-300}" \
    "${base}${path}" -o "$output"
}

# Print the useful payload of an API action response.  Session mutations return
# {ok,session}; snapshot returns {ok,id,snapshot,image}.  Everything else is
# printed as-is.
beaut_api_payload() {
  local json="$1"
  jq -c 'if .session then .session elif .manifest then .manifest else . end' \
    <<<"$json" 2>/dev/null || printf '%s\n' "$json"
}

# Extract the error string from an API response, falling back to the raw body
# (the API also returns plain-text errors such as "not found").
beaut_api_error_text() {
  local body="${1:-}" message
  message="$(jq -r '.error // empty' <<<"$body" 2>/dev/null || true)"
  if [[ -n "$message" ]]; then
    printf '%s' "$message"
  else
    printf '%s' "$body"
  fi
}

beaut_api_ok() {
  local body="${1:-}"
  jq -e '.ok != false' >/dev/null 2>&1 <<<"$body"
}
