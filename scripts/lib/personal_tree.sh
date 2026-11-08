#!/usr/bin/env bash
# lib/personal_tree.sh — hidden personal tree and its secret path (sourced).
#
# The tree is ordinary static files; only its URL prefix is secret. Nothing is
# listed or generated at request time. Modes:
#   random : eight lowercase alphanumeric characters, persisted once (default)
#   sha    : first eight characters of sha256("beaut-svr:" + SVR_SECRET)
#   plain  : an explicit SVR value (opt-in, less private)
set -uo pipefail

PERSONAL_TREE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F has_command >/dev/null 2>&1; then
  . "$PERSONAL_TREE_LIB_DIR/core.sh"
fi
. "$PERSONAL_TREE_LIB_DIR/passphrase.sh"

personal_tree_root() {
  if [[ -n "${SVR_ROOT:-}" ]]; then
    printf '%s' "$SVR_ROOT"
  elif [[ -n "${SERVICE_ROOT:-}" ]]; then
    printf '%s' "$SERVICE_ROOT/svr"
  else
    printf '%s' "${STATE_DIR:?STATE_DIR is required}/../svr"
  fi
}

personal_tree_path_file() {
  printf '%s' "${SVR_PATH_FILE:-${STATE_DIR:?STATE_DIR is required}/svr_path}"
}

personal_tree_sha256() {
  local value="${1:-}"
  if has_command sha256sum; then
    printf '%s' "$value" | sha256sum | awk '{print $1}'
  elif has_command shasum; then
    printf '%s' "$value" | shasum -a 256 | awk '{print $1}'
  elif has_command openssl; then
    printf '%s' "$value" | openssl dgst -sha256 | awk '{print $NF}'
  else
    printf 'no SHA-256 tool available (sha256sum, shasum or openssl)\n' >&2
    return 1
  fi
}

personal_tree_validate_plain_path() {
  local path="${1:-}"
  [[ -n "$path" ]] || return 1
  [[ "$path" != "." && "$path" != ".." ]] || return 1
  [[ "$path" =~ ^[A-Za-z0-9._-]{1,64}$ ]]
}

personal_tree_generate_random_path() {
  passphrase_random_alphanumeric 8
}

# Print the bare (no leading slash) secret path for the current mode.
personal_tree_current_path() {
  local mode="${SVR_MODE:-random}" path_file existing sha
  case "$mode" in
    random)
      path_file="$(personal_tree_path_file)"
      if [[ -s "$path_file" ]]; then
        existing="$(tr -d '[:space:]' < "$path_file")"
        if [[ "$existing" =~ ^[a-z0-9]{8}$ ]]; then
          printf '%s' "$existing"
          return 0
        fi
        log warn "ignoring invalid SVR path in $path_file"
      fi
      existing="$(personal_tree_generate_random_path)"
      mkdir -p -- "$(dirname "$path_file")"
      (umask 077; printf '%s\n' "$existing" > "$path_file")
      chmod 600 "$path_file"
      printf '%s' "$existing"
      ;;
    sha)
      [[ -n "${SVR_SECRET:-}" ]] || {
        printf 'SVR_MODE=sha requires SVR_SECRET\n' >&2
        return 1
      }
      sha="$(personal_tree_sha256 "beaut-svr:$SVR_SECRET")" || return 1
      printf '%s' "${sha:0:8}"
      ;;
    plain)
      personal_tree_validate_plain_path "${SVR:-}" || {
        printf 'SVR_MODE=plain requires a safe SVR value ([A-Za-z0-9._-], max 64)\n' >&2
        return 1
      }
      printf '%s' "$SVR"
      ;;
    *)
      printf 'invalid SVR_MODE: %s (random, sha or plain)\n' "$mode" >&2
      return 1
      ;;
  esac
}

personal_tree_url_path() {
  local path
  path="$(personal_tree_current_path)" || return 1
  printf '/%s' "$path"
}

# Return the path relative to the personal tree when url_path is under the
# secret prefix. An empty result means the tree root itself.
personal_tree_match_path() {
  local url_path="${1:-}" hidden
  hidden="$(personal_tree_current_path)" || return 1
  [[ -n "$hidden" ]] || return 1
  case "$url_path" in
    "$hidden")
      printf ''
      return 0
      ;;
    "$hidden"/*)
      printf '%s' "${url_path#"$hidden"/}"
      return 0
      ;;
  esac
  return 1
}

personal_tree_default_script() {
  cat <<'DEFAULT_SCRIPT'
#!/bin/sh
# Static welcome script for the hidden personal tree. No listing is generated.
printf 'beaut personal tree\n'
printf 'journal: diary/YYYY-MM-DD.md\n'
DEFAULT_SCRIPT
}

personal_tree_initialize() {
  local root path diary notes default_script
  root="$(personal_tree_root)"
  path="$(personal_tree_current_path)" || return 1
  diary="$root/diary"
  notes="$root/notes"
  default_script="$root/DEFAULT.sh"

  mkdir -p -- "$root" "$diary" "$notes"
  chmod 700 "$root" "$diary" "$notes" 2>/dev/null || true
  if [[ ! -f "$default_script" ]]; then
    personal_tree_default_script > "$default_script"
    chmod 755 "$default_script"
  fi
  printf '%s' "$path"
}
