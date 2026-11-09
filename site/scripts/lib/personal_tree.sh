#!/usr/bin/env bash
# lib/personal_tree.sh — hidden personal tree and its secret URL path (sourced).
#
# The tree is ordinary static files. Both its on-disk directory and its URL
# prefix are secret: the directory is SVR_DIR or a random hidden name persisted
# in SVR_DIR_FILE. Modes for the URL prefix:
#   random : eight lowercase alphanumeric characters, persisted once (default)
#   sha    : first eight characters of sha256("beaut-svr:" + SVR_SECRET)
#   plain  : an explicit SVR value (opt-in, less private)
set -uo pipefail

PERSONAL_TREE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F has_command >/dev/null 2>&1; then
  . "$PERSONAL_TREE_LIB_DIR/core.sh"
fi
. "$PERSONAL_TREE_LIB_DIR/passphrase.sh"

personal_tree_path_file() {
  printf '%s' "${SVR_PATH_FILE:-${STATE_DIR:?STATE_DIR is required}/svr_path}"
}

personal_tree_directory_file() {
  printf '%s' "${SVR_DIR_FILE:-${STATE_DIR:?STATE_DIR is required}/svr_dir}"
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

# Print the bare (no leading slash) on-disk directory name. SVR_DIR wins when
# explicitly set; otherwise a random hidden name is generated once and stored
# in SVR_DIR_FILE with mode 600.
personal_tree_directory_name() {
  local directory_file existing
  if [[ -n "${SVR_DIR:-}" ]]; then
    personal_tree_validate_plain_path "$SVR_DIR" || {
      printf 'invalid SVR_DIR: %s ([A-Za-z0-9._-], max 64)\n' "$SVR_DIR" >&2
      return 1
    }
    printf '%s' "$SVR_DIR"
    return 0
  fi
  directory_file="$(personal_tree_directory_file)"
  if [[ -s "$directory_file" ]]; then
    existing="$(tr -d '[:space:]' < "$directory_file")"
    if personal_tree_validate_plain_path "$existing"; then
      printf '%s' "$existing"
      return 0
    fi
    log warn "ignoring invalid SVR directory in $directory_file"
  fi
  existing=".svr-$(personal_tree_generate_random_path)"
  mkdir -p -- "$(dirname "$directory_file")"
  (umask 077; printf '%s\n' "$existing" > "$directory_file")
  chmod 600 "$directory_file"
  printf '%s' "$existing"
}

personal_tree_root() {
  local name
  if [[ -n "${SVR_ROOT:-}" ]]; then
    printf '%s' "$SVR_ROOT"
    return 0
  fi
  name="$(personal_tree_directory_name)" || return 1
  if [[ -n "${SERVICE_ROOT:-}" ]]; then
    printf '%s/%s' "$SERVICE_ROOT" "$name"
  else
    printf '%s/%s' "${STATE_DIR:?STATE_DIR is required}/.." "$name"
  fi
}

# The historical tree lived in $SERVICE_ROOT/svr; the journal in diary/.
# Migrate both once, without overwriting anything that already exists.
personal_tree_legacy_root() {
  [[ -n "${SERVICE_ROOT:-}" ]] && printf '%s/svr' "$SERVICE_ROOT"
}

personal_tree_migrate() {
  local root legacy
  root="$(personal_tree_root)" || return 1
  legacy="$(personal_tree_legacy_root)"
  if [[ -n "$legacy" && "$legacy" != "$root" && -d "$legacy" && ! -e "$root" ]]; then
    mv -- "$legacy" "$root" || return 1
  fi
  if [[ -d "$root/diary" && ! -e "$root/journal" ]]; then
    mv -- "$root/diary" "$root/journal" || return 1
  fi
}

# Print the bare (no leading slash) URL prefix for the current mode.
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
      sha="$(sha256_hex "beaut-svr:$SVR_SECRET")" || return 1
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
# Static welcome script for the hidden personal tree.
printf 'beaut personal tree\n'
printf 'journal: journal/YYYY/MM/DD/<subfolder>/<name>.md\n'
DEFAULT_SCRIPT
}

personal_tree_initialize() {
  local root path notes default_script
  root="$(personal_tree_root)" || return 1
  personal_tree_migrate
  path="$(personal_tree_current_path)" || return 1
  notes="$root/notes"
  default_script="$root/DEFAULT.sh"

  mkdir -p -- "$root" "$notes"
  chmod 700 "$root" "$notes" 2>/dev/null || true
  if [[ ! -f "$default_script" ]]; then
    personal_tree_default_script > "$default_script"
    chmod 755 "$default_script"
  fi
  printf '%s' "$path"
}
