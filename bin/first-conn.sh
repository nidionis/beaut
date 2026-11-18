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

. "$(dirname -- "$0")/../lib/bootstrap.sh"
. "$(dirname -- "$0")/../lib/deploy.sh"

usage() {
  printf 'usage: first-conn.sh ROLE TARGET SUDO_USER [PASSWORD]\n' >&2
  exit 2
}

usage_error() {
  printf 'first-conn: %s\n' "$*" >&2
  exit 2
}

[[ $# -ge 3 && $# -le 4 ]] || usage
is_role "$ROLE" || usage_error 'ROLE must be hub or worker'
is_explicit_address "$TARGET" ||
  usage_error 'TARGET must be an explicit non-loopback address'
[[ -n "$SUDO_USER" ]] || usage_error 'SUDO_USER is empty'

load_config
validate_config
need ssh
need tar
[[ -n "$PASSWORD" ]] && need sshpass

ensure_key "$NODE_KEY"
PUBLIC_KEY="$(<"$NODE_KEY.pub")"

first_conn_ssh() {
  deploy_first_ssh "$SUDO_USER" "$TARGET" "$PASSWORD" "$@"
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
address="$(deploy_role_address "$ROLE" "$TARGET")" ||
  die "unknown deploy role: $ROLE"
deploy_write_node "$ROLE" "$address" "$admin_target"

printf 'first-conn: %s ready at %s\n' "$ROLE" "$TARGET"
printf 'next: %s/bin/deploy-%s.sh\n' "$BEAUT_ROOT" "$ROLE"
