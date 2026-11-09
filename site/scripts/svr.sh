#!/usr/bin/env bash
# svr.sh — personal tree (SVR_NAME symlink), git-backed journal and installer.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/core.sh"
. "$SCRIPT_DIR/lib/personal_tree.sh"
. "$SCRIPT_DIR/lib/journal.sh"
load_config

usage() {
  cat >&2 <<'EOF'
usage: svr.sh <command>
  init                    create SVR_ROOT, journals and $SVR_NAME symlink
  link                    (re)create symlinks
  install [bin_dir]       install journal and journal-perso in the user PATH
  path                    print the URL path (/$SVR_NAME)
  status                  print name, root and remotes
  journal ...             add/list/show/sync/remote, or [subfolder] <name>
  journal-perso ...       personal journal, or [subfolder] <name>
  sync                    pull and push the svr repo
  push                    push journal and perso remotes
  remote [url]            show or set the git remote
EOF
  exit 2
}

svr_add_path_block() {
  local file="$1"
  [[ -n "$file" ]] || return 1
  if [[ -f "$file" ]] && grep -qF 'beaut: journal commands' "$file"; then return 0; fi
  mkdir -p -- "$(dirname "$file")" || return 1
  {
    printf '\n# beaut: journal commands\n'
    printf 'case ":$PATH:" in\n'
    printf '  *":$HOME/.local/bin:"*) ;;\n'
    printf '  *) PATH="$HOME/.local/bin:$PATH"; export PATH ;;\n'
    printf 'esac\n'
  } >> "$file"
}

svr_ensure_user_path() {
  local bin_dir="$1" login_file file
  [[ "${SVR_INSTALL_PATH:-1}" == "1" ]] || return 0
  [[ -n "${HOME:-}" && "$bin_dir" == "$HOME/.local/bin" ]] || return 0
  case ":$PATH:" in *":$bin_dir:"*) return 0 ;; esac
  login_file=''
  for file in .bash_profile .bash_login .profile; do
    [[ -e "$HOME/$file" ]] && { login_file="$HOME/$file"; break; }
  done
  [[ -n "$login_file" ]] || login_file="$HOME/.profile"
  svr_add_path_block "$login_file" || return 1
  [[ -e "$HOME/.bashrc" ]] && svr_add_path_block "$HOME/.bashrc" || true
}

svr_install() {
  local bin_dir="${1:-${SVR_BIN_DIR:-$HOME/.local/bin}}"
  local source="$SCRIPT_DIR/journal_cli.sh"
  [[ -f "$source" ]] || { printf 'missing journal command: %s\n' "$source" >&2; return 1; }
  mkdir -p -- "$bin_dir" || return 1
  chmod 755 "$source" 2>/dev/null || true
  ln -sfn -- "$source" "$bin_dir/journal"
  ln -sfn -- "$source" "$bin_dir/journal-perso"
  printf 'installed: %s/journal\n           %s/journal-perso\n' "$bin_dir" "$bin_dir"
  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) if svr_ensure_user_path "$bin_dir"; then
         printf 'PATH: added %s to the login shell startup files\n' "$bin_dir"
       else
         printf 'add %s to PATH\n' "$bin_dir" >&2
       fi ;;
  esac
}

svr_remote() {
  local root="$1" url="${2:-}"
  if [[ -n "$url" ]]; then
    url="$(journal_remote_resolve "$url" "$root")" || return 1
    journal_remote_set "$root" "$url" || return 1
    journal_git_push "$root"
    printf 'remote: %s\n' "$url"
  else
    journal_remote_get "$root" || { printf 'no remote for %s\n' "$root" >&2; return 1; }
  fi
}

svr_status() {
  local name root journal perso remote
  name="$(personal_tree_name)" || return 1
  root="$(personal_tree_root)" || return 1
  journal="$(journal_root)" || return 1
  perso="$(journal_perso_root)" || return 1
  printf 'name: %s\npath: %s\nroot: %s\njournal: %s\nperso: %s\n' \
    "$name" "$(personal_tree_url_path)" "$root" "$journal" "$perso"
  remote="$(journal_remote_get "$root" 2>/dev/null || true)"
  [[ -n "$remote" ]] && printf 'remote: %s\n' "$remote"
  return 0
}

command="${1:-}"
[[ -n "$command" ]] || usage
shift

case "$command" in
  init)
    path="$(personal_tree_initialize)" || exit 1
    journal_initialize || exit 1
    journal_perso_initialize || exit 1
    journal_ensure_pushable "$(journal_root)" || true
    journal_ensure_pushable "$(journal_perso_root)" || true
    personal_tree_link_site || exit 1
    if [[ "${JOURNAL_GIT:-1}" == "1" ]] && has_command git; then
      journal_git_run "$(personal_tree_root)" add -A >/dev/null 2>&1 || true
      journal_git_run "$(personal_tree_root)" commit -m "svr: initialize $path" >/dev/null 2>&1 || true
    fi
    printf 'personal tree: /%s\nroot: %s\njournal: %s\nperso: %s\n' \
      "$path" "$(personal_tree_root)" "$(journal_root)" "$(journal_perso_root)"
    ;;
  link) personal_tree_link_site || exit 1 ;;
  install) svr_install "${1:-}" || exit 1 ;;
  path) personal_tree_url_path || exit 1; printf '\n' ;;
  status) svr_status || exit 1 ;;
  sync) journal_sync "$(personal_tree_root)" ;;
  remote) svr_remote "$(personal_tree_root)" "${1:-}" || exit 1 ;;
  journal)
    action="${1:-}"
    case "$action" in
      add) shift; journal_add "$*"; printf '\n' ;;
      list) shift; journal_list "${1:-0}" ;;
      show) shift; journal_show "$@" ;;
      sync) journal_sync "$(personal_tree_root)" ;;
      remote) shift; svr_remote "$(personal_tree_root)" "${1:-}" || exit 1 ;;
      *) journal_open "$@"; printf '\n' ;;
    esac
    ;;
  journal-perso)
    action="${1:-}"
    case "$action" in
      list) shift; journal_list "${1:-0}" "$(journal_perso_root)" ;;
      show) shift; JOURNAL_ROOT="$(journal_perso_root)" journal_show "$@" ;;
      sync) journal_sync "$(personal_tree_root)" ;;
      *) journal_perso_open "$@"; printf '\n' ;;
    esac
    ;;
  *) usage ;;
esac
