#!/usr/bin/env bash
# deploy.sh — deploy the minimal beaut server on $SERVER_HOST.
#
#   ./deploy.sh              remote installation (SSH/SFTP) on $SERVER_HOST
#   ./deploy.sh --no-root    remote installation as SERVICE_USER, without sudo
#   ./deploy.sh --debug      verbose remote diagnostics
#
# Install modes:
#   privileged (default): SERVICE_USER is used directly when its key and
#     passwordless sudo already work. A fresh host falls back to BOOTSTRAP_USER,
#     which applies deploy/files/bootstrap.sh: creates SERVICE_USER, authorizes
#     its key, installs the root-owned copy, writes the sudo grant, starts the
#     service. WireGuard is configured through the sudo grant.
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
# The normal case is an already bootstrapped host: SERVICE_USER authenticates
# with the configured key and passwordless sudo works. Only a fresh host needs
# BOOTSTRAP_USER, which is then used as the first application identity.
service_user_is_ready() {
  as_service_user true >/dev/null 2>&1 || return 1
  as_service_user 'sudo -n true' >/dev/null 2>&1 || return 1
  return 0
}

choose_bootstrap_user() {
  local fallback="${BOOTSTRAP_USER:-root}"
  BOOTSTRAP_USER="$fallback"
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
  copy_to_service_user "$PROJECT_ROOT/config.env.example" \
    "$SERVICE_USER@$SERVER_HOST:.beaut/config.env.example" \
    || die "cannot copy the configuration schema"
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
# /node is published as a self-contained artifact rendered ON THE SERVER from
# the uploaded scripts/node.sh and the deployed config: no local client file is
# uploaded and `curl .../node | sh` works with zero client files.
# /join is not published; scripts/wireguard_join.sh stays a repo command.
publish_tree() {
  case "$SERVER_HOST" in
    ''|*[!A-Za-z0-9._:-]*) die "invalid SERVER_HOST: $SERVER_HOST" ;;
  esac
  case "$HTTP_PORT" in
    ''|*[!0-9]*) die "invalid HTTP_PORT: $HTTP_PORT" ;;
  esac

  as_service_user "set -e
    cd ~/.beaut
    mkdir -p shared/node
    rm -rf shared/scripts shared/deploy shared/join
    cp -a scripts shared/scripts
    cp -a deploy shared/deploy
    bash scripts/build_published_node.sh '$SERVER_HOST' '$HTTP_PORT' > shared/node/DEFAULT.sh
    chmod -R a+rX shared" || die "cannot publish the HTTP tree"
}

# Refresh the root-owned privileged copy without re-running bootstrap. The
# service user already has sudo, so this does not widen its rights; it keeps
# network.sh/wireguard.sh current between deploys.
install_privileged_scripts() {
  as_service_user "sudo -n env SERVICE_HOME=\"\$HOME\" bash ~/.beaut/deploy/files/install_privileged.sh" \
    || die "cannot refresh the privileged scripts"
}

# --- 4b. local identities and the hidden personal tree ----------------------
initialize_identity() {
  if [[ "$INSTALL_MODE" == "root" ]]; then
    as_service_user 'cd ~/.beaut && bash scripts/device.sh init "$(hostname 2>/dev/null || printf server)"' \
      || die "cannot initialize the server device identity"
  else
    log info "no-root mode: skipping the server device identity (no WireGuard)"
  fi
  as_service_user 'cd ~/.beaut && bash scripts/svr.sh init' \
    || die "cannot initialize the personal tree"
}

# --- 5. privileged resources through the sudo grant -------------------------
configure_network() {
  as_service_user "if command -v wg >/dev/null 2>&1; then
            sudo -n bash /usr/local/lib/beaut/scripts/network.sh setup || echo 'warning: network not configured' >&2
            sudo -n bash /usr/local/lib/beaut/scripts/network.sh sync-peers || echo 'warning: peers not synchronized' >&2
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

  if [[ "$INSTALL_MODE" == "root" ]] && ! service_user_is_ready; then
    choose_bootstrap_user
    log info "bootstrapping $SERVER_HOST through $BOOTSTRAP_USER, then $SERVICE_USER"
    bootstrap_remote
    verify_key_auth
    log info "key accepted for $SERVICE_USER@$SERVER_HOST"
  else
    if [[ "$INSTALL_MODE" == "root" ]]; then
      log info "identity detected: $SERVICE_USER@$SERVER_HOST (key + sudo)"
    else
      log info "no-root mode: installing $SERVER_HOST as $SERVICE_USER without sudo"
    fi
    verify_key_auth
  fi

  upload_tree
  if [[ "$INSTALL_MODE" == "root" ]]; then
    install_privileged_scripts
  fi
  init_git_repo
  publish_tree
  initialize_identity

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
