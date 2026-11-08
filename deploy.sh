#!/usr/bin/env bash
# deploy.sh — deploy the minimal beaut server on $SERVER_HOST.
#
#   ./deploy.sh              remote installation (SSH/SFTP) on $SERVER_HOST
#   ./deploy.sh --no-root    remote installation as SERVICE_USER, without sudo
#   ./deploy.sh --debug      verbose remote diagnostics
#
# Install modes:
#   privileged (default): BOOTSTRAP_USER (root recommended) applies
#     deploy/files/bootstrap.sh: creates SERVICE_USER, authorizes its key,
#     installs the root-owned copy, writes the sudo grant, starts the service.
#     WireGuard is configured through the sudo grant.
#   user (--no-root): connect as SERVICE_USER with the key only, install under
#     $HOME/.beaut and start the service without any sudo; no WireGuard.
#
# Then, everything else runs as SERVICE_USER (private key, no password), inside
# $HOME/.beaut: scripts/, deploy/, state/, shared/ (the HTTP tree).
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DEPLOY_DIR/scripts/lib/core.sh"
load_config

DEBUG="${DEBUG:-0}"

INSTALL_MODE="root"
if [[ "${1:-}" == "--no-root" ]]; then
  INSTALL_MODE="user"
  shift
fi
if [[ "${1:-}" == "--debug" ]]; then
  DEBUG=1
  shift
fi

CONFIG_FILE="$PROJECT_ROOT/config.env"
[[ -f "$CONFIG_FILE" ]] || CONFIG_FILE="$PROJECT_ROOT/config.env.example"

LOCAL_PAYLOAD=""
cleanup() { if [[ -n "$LOCAL_PAYLOAD" ]]; then rm -f -- "$LOCAL_PAYLOAD"; fi; }
trap cleanup EXIT

# --- identity ---------------------------------------------------------------
choose_bootstrap_user() {
  local default="${BOOTSTRAP_USER:-root}" answer=""
  if [[ -t 0 ]]; then
    read -r -p "Bootstrap user for the first connection [$default]: " answer < /dev/tty || true
  fi
  BOOTSTRAP_USER="${answer:-$default}"
  [[ -n "$BOOTSTRAP_USER" ]] || die "BOOTSTRAP_USER is empty"
}

# --- connection as SERVICE_USER (key only, never a password) ----------------
SSH_BASE=(-o BatchMode=yes -o IdentitiesOnly=yes
          -o PreferredAuthentications=publickey -o StrictHostKeyChecking=accept-new)
if [[ "$DEBUG" -eq 1 ]]; then
  SSH_BASE+=(-o LogLevel=DEBUG3)
fi
as_service_user() { ssh -n -i "$SSH_PRIVATE_KEY" "${SSH_BASE[@]}" "$SERVICE_USER@$SERVER_HOST" "$@"; }
copy_to_service_user() { scp -i "$SSH_PRIVATE_KEY" "${SSH_BASE[@]}" "$@"; }
remote_run() { ssh -n -i "$SSH_PRIVATE_KEY" "${SSH_BASE[@]}" "$SERVICE_USER@$SERVER_HOST" 'bash -s' < "$1"; }

# --- 1. bootstrap through BOOTSTRAP_USER ------------------------------------
bootstrap_remote() {
  local public_key_b64 assignments remote_payload
  [[ -f "$SSH_PRIVATE_KEY" ]]     || die "private key not found: $SSH_PRIVATE_KEY"
  [[ -f "$SSH_PRIVATE_KEY.pub" ]] || die "public key not found: $SSH_PRIVATE_KEY.pub"

  public_key_b64="$(base64 -w0 < "$SSH_PRIVATE_KEY.pub")"
  remote_payload="/tmp/beaut-bootstrap.$$.tgz"
  LOCAL_PAYLOAD="$(mktemp "${TMPDIR:-/tmp}/beaut.XXXXXX.tgz")"
  tar -czf "$LOCAL_PAYLOAD" -C "$PROJECT_ROOT" scripts deploy config.env.example

  scp "$LOCAL_PAYLOAD" "$BOOTSTRAP_USER@$SERVER_HOST:$remote_payload" \
    || die "cannot upload bootstrap payload (BOOTSTRAP_USER=$BOOTSTRAP_USER)"

  assignments="SERVICE_USER=$SERVICE_USER PUBLIC_KEY_B64=$public_key_b64 PAYLOAD_ARCHIVE=$remote_payload"

  # One SSH call: pick root or passwordless sudo, then feed bootstrap.sh on stdin.
  ssh "$BOOTSTRAP_USER@$SERVER_HOST" "
    if [ \"\$(id -u)\" -eq 0 ]; then
      exec env $assignments bash -s
    elif sudo -n true 2>/dev/null; then
      exec sudo -n env $assignments bash -s
    else
      echo 'error: $BOOTSTRAP_USER needs passwordless sudo: use BOOTSTRAP_USER=root' >&2
      exit 1
    fi" < "$FILES_DIR/bootstrap.sh" || die "bootstrap failed on $SERVER_HOST"

  rm -f -- "$LOCAL_PAYLOAD"; LOCAL_PAYLOAD=""
}

# --- 2. verify passwordless key authentication ------------------------------
verify_key_auth() {
  as_service_user true || die "key refused for $SERVICE_USER@$SERVER_HOST (authorized_keys, home permissions, StrictModes?)"
}

# --- 3. upload, then everything as SERVICE_USER -----------------------------
upload_tree() {
  copy_to_service_user -r "$SCRIPTS_DIR" "$PROJECT_ROOT/deploy" "$SERVICE_USER@$SERVER_HOST:.beaut/" \
    || die "cannot copy scripts"
  copy_to_service_user "$CONFIG_FILE" "$SERVICE_USER@$SERVER_HOST:.beaut/config.env" \
    || die "cannot copy configuration"
  as_service_user "find ~/.beaut -type f -name '*.sh' -exec chmod 755 {} +" \
    || die "remote chmod failed"
}

init_git_repo() {
  as_service_user 'cd ~/.beaut && if command -v git >/dev/null 2>&1; then
            git init -q
            git add -A
            git commit -qm "deploy: initial installation" >/dev/null 2>&1 || true
          else
            echo "git not found: repository not initialized" >&2
          fi' || true
}

# --- 4. HTTP tree: the path mirrors the file --------------------------------
publish_tree() {
  as_service_user 'set -e
    cd ~/.beaut
    mkdir -p shared
    rm -rf shared/scripts shared/deploy
    cp -a scripts shared/scripts
    cp -a deploy shared/deploy
    mkdir -p shared/node
    cp -f scripts/node.sh shared/node/DEFAULT.sh
    cp -f scripts/wireguard_join.sh shared/join
    chmod -R a+rX shared' || die "cannot publish the HTTP tree"
}

# --- 5. privileged resources through the sudo grant -------------------------
configure_network() {
  as_service_user "if command -v wg >/dev/null 2>&1; then
            sudo -n bash /usr/local/lib/beaut/scripts/network.sh setup || echo 'warning: network not configured' >&2
          else
            echo 'warning: wireguard missing, network skipped' >&2
          fi" || true
}

wait_for_server() {
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS "http://$SERVER_HOST:$HTTP_PORT/work" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  log error "server unreachable on http://$SERVER_HOST:$HTTP_PORT (~/.beaut/state/http.log, journal: systemctl --user -u beaut.service)"
  as_service_user 'systemctl --user status beaut.service --no-pager -l 2>&1; journalctl --user -u beaut.service -n 40 --no-pager 2>&1' >/dev/null 2>&1 || true
  return 1
}

install_server() {
  has_command ssh  || die "ssh is required"
  has_command scp  || die "scp is required"
  has_command curl || die "curl is required"

  if [[ "$INSTALL_MODE" == "root" ]]; then
    choose_bootstrap_user
    log info "bootstrapping $SERVER_HOST through $BOOTSTRAP_USER, then $SERVICE_USER"
    bootstrap_remote
    verify_key_auth
    log info "key accepted for $SERVICE_USER@$SERVER_HOST"
  else
    log info "no-root mode: installing $SERVER_HOST as $SERVICE_USER without sudo"
    verify_key_auth
  fi

  upload_tree
  init_git_repo
  publish_tree

  if [[ "$INSTALL_MODE" == "root" ]]; then
    configure_network
  else
    log info "no-root mode: skipping network/WireGuard configuration (no sudo)"
  fi

  remote_run "$FILES_DIR/remote_install.sh"

  if wait_for_server; then
    log info "server active: http://$SERVER_HOST:$HTTP_PORT"
    log info "node: curl -fsS http://$SERVER_HOST:$HTTP_PORT/node | sh"
  else
    log error "server unreachable on http://$SERVER_HOST:$HTTP_PORT (~/.beaut/state/http.log)"
    as_service_user 'systemctl --user status beaut.service --no-pager -l 2>&1; journalctl --user -u beaut.service -n 40 --no-pager 2>&1' >/dev/null 2>&1 || true
    exit 1
  fi
  log info "installation complete on $SERVER_HOST (user $SERVICE_USER)"
}

install_server
