#!/usr/bin/env bash
# first-conn.sh ROLE TARGET SUDO_USER [PASSWORD]
#
# First connection to a new node: verify SSH/sudo, create the admin and worker
# accounts, install the installer key, prepare $ROOT and install the tree.
# PASSWORD is optional, passed to sshpass and never written to disk.
set -uo pipefail

ROLE="${1:-}"
TARGET="${2:-}"
SUDO_USER="${3:-}"
PASSWORD="${4:-}"
[[ $# -ge 3 && $# -le 4 ]] ||
  {
    printf 'usage: first-conn.sh ROLE TARGET SUDO_USER [PASSWORD]\n' >&2
    exit 2
  }
case "$ROLE" in
  hub|worker) ;;
  *)
    printf 'first-conn: ROLE must be hub or worker\n' >&2
    exit 2
    ;;
esac
case "$TARGET" in
  ""|localhost|127.*|::1|"[::1]")
    printf 'first-conn: TARGET must be an explicit non-loopback address\n' >&2
    exit 2
    ;;
esac
[[ -n "$SUDO_USER" ]] || {
  printf 'first-conn: SUDO_USER is empty\n' >&2
  exit 2
}

. "$(dirname -- "$0")/../lib/bootstrap.sh"
. "$(dirname -- "$0")/../lib/deploy.sh"
load_config
validate_config
need ssh
need ssh-keygen
need tar
[[ -n "$PASSWORD" ]] && need sshpass

ensure_dir "$KEYS_DIR" 700
if [[ ! -f "$NODE_KEY" ]]; then
  ssh-keygen -q -t ed25519 -N '' -f "$NODE_KEY" </dev/null ||
    die "cannot create installer key: $NODE_KEY"
fi
PUBLIC_KEY="$(<"$NODE_KEY.pub")"

first_conn_ssh() {
  local -a opts filtered
  local i=0
  read -r -a opts <<<"$SSH_OPTS"
  while (( i < ${#opts[@]} )); do
    if [[ "${opts[i]}" == -o && "${opts[i + 1]:-}" == BatchMode=yes ]]; then
      i=$((i + 2))
      continue
    fi
    if [[ "${opts[i]}" == BatchMode=yes ]]; then
      i=$((i + 1))
      continue
    fi
    filtered+=("${opts[i]}")
    i=$((i + 1))
  done
  if [[ -f "$NODE_KEY" ]]; then
    filtered+=(-i "$NODE_KEY")
  fi
  if [[ -n "$PASSWORD" ]]; then
    SSHPASS="$PASSWORD" sshpass -e ssh "${filtered[@]}" "$SUDO_USER@$TARGET" "$@"
  else
    ssh "${filtered[@]}" "$SUDO_USER@$TARGET" "$@"
  fi
}

first_conn_ssh 'id -un' >/dev/null || die "cannot log in to $SUDO_USER@$TARGET"
sudo_ok=no
if first_conn_ssh 'sudo -n true' 2>/dev/null; then
  sudo_ok=yes
elif [[ -z "$PASSWORD" ]]; then
  die "sudo needs a password on $TARGET (pass PASSWORD or allow NOPASSWD)"
fi

bootstrap_root=""
[[ "$ROOT" != "$HOME/.beaut" ]] && bootstrap_root="$ROOT"
script="$(render_template "$BEAUT_ROOT/share/templates/first-conn.sh" \
  ADMIN_USER "$(sh_quote "$ADMIN_USER")" \
  WORKER_USER "$(sh_quote "$WORKER_USER")" \
  ROOT "$(sh_quote "$bootstrap_root")" \
  PUBLIC_KEY "$(sh_quote "$PUBLIC_KEY")")"

if [[ "$sudo_ok" == no ]]; then
  printf '%s\n%s\n' "$PASSWORD" "$script" |
    first_conn_ssh 'sudo -S -p "" bash -s' ||
    die "remote bootstrap failed on $TARGET"
else
  printf '%s\n' "$script" |
    first_conn_ssh 'sudo -n bash -s' ||
    die "remote bootstrap failed on $TARGET"
fi

admin_target="$ADMIN_USER@$TARGET"
deploy_remote_paths "$admin_target"
deploy_sync_tree "$admin_target"
deploy_write_config "$admin_target"
case "$ROLE" in
  hub) address="$HUB" ;;
  worker) address="${WORKER_ADDRESS:-$TARGET}" ;;
esac
deploy_write_node "$ROLE" "$address" "$admin_target"

printf 'first-conn: %s ready at %s\n' "$ROLE" "$TARGET"
printf 'next: %s/bin/deploy-%s.sh\n' "$BEAUT_ROOT" "$ROLE"
