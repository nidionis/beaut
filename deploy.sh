#!/usr/bin/env bash
# deploy.sh — bootstrap beaut on $SERVER_HOST.
#
#   ./deploy.sh              remote installation (SSH/SFTP)
#   ./deploy.sh --no-root    local installation, no system privileges
#
# Two phases, one identity switch:
#   1. BOOTSTRAP_USER (root recommended) applies deploy/files/bootstrap.sh:
#      creates SERVICE_USER, authorizes the key, installs the root-owned script
#      copy and the s$SERVICE_USER helper.
#   2. everything else runs as SERVICE_USER (private key, no password), inside
#      $HOME/.beaut: scripts, deploy, state, shared (the HTTP tree).
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DEPLOY_DIR/scripts/lib/core.sh"
load_config

LOCAL_MODE=0
if [[ "${1:-}" == "--no-root" ]]; then LOCAL_MODE=1; fi

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
SSH_OPTIONS=(-o BatchMode=yes -o IdentitiesOnly=yes
             -o PreferredAuthentications=publickey -o StrictHostKeyChecking=accept-new)
as_service_user() { ssh -n -i "$SSH_PRIVATE_KEY" "${SSH_OPTIONS[@]}" "$SERVICE_USER@$SERVER_HOST" "$@"; }
copy_to_service_user() { scp -i "$SSH_PRIVATE_KEY" "${SSH_OPTIONS[@]}" "$@"; }

# --- 1. bootstrap through BOOTSTRAP_USER ------------------------------------
bootstrap_remote() {
  local public_key_b64 assignments remote_payload
  [[ -f "$SSH_PRIVATE_KEY" ]]     || die "private key not found: $SSH_PRIVATE_KEY"
  [[ -f "$SSH_PRIVATE_KEY.pub" ]] || die "public key not found: $SSH_PRIVATE_KEY.pub"

  public_key_b64="$(base64 -w0 < "$SSH_PRIVATE_KEY.pub")"
  remote_payload="/tmp/beaut-bootstrap.$$.tgz"
  LOCAL_PAYLOAD="$(mktemp "${TMPDIR:-/tmp}/beaut.XXXXXX.tgz")"
  tar -czf "$LOCAL_PAYLOAD" -C "$PROJECT_ROOT" scripts deploy

  scp "$LOCAL_PAYLOAD" "$BOOTSTRAP_USER@$SERVER_HOST:$remote_payload" \
    || die "cannot upload bootstrap payload (BOOTSTRAP_USER=$BOOTSTRAP_USER)"

  assignments="SERVICE_USER=$(printf '%q' "$SERVICE_USER") PUBLIC_KEY_B64=$public_key_b64 PAYLOAD_ARCHIVE=$(printf '%q' "$remote_payload") SERVER_HOST=$(printf '%q' "$SERVER_HOST") HTTP_PORT=$(printf '%q' "$HTTP_PORT") WG_PORT=$(printf '%q' "$WG_PORT") WG_NETWORK=$(printf '%q' "$WG_NETWORK") WG_SERVER_IP=$(printf '%q' "$WG_SERVER_IP") TOKEN_TTL_SECONDS=$(printf '%q' "$TOKEN_TTL_SECONDS")"

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
  as_service_user "find ~/.beaut -type f \( -name '*.sh' -o -name 'sbeaut' \) -exec chmod 755 {} +" \
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

# --- 5. privileged resources through the scoped helper ----------------------
configure_network() {
  as_service_user "if command -v wg >/dev/null 2>&1; then
            sudo -n s$SERVICE_USER || echo 'warning: network not configured' >&2
          else
            echo 'warning: wireguard missing, network skipped' >&2
          fi" || true
}

# --- 6. user service (setsid fallback) --------------------------------------
start_service() {
  as_service_user 'set -e
    mkdir -p ~/.config/systemd/user
    cp -f ~/.beaut/deploy/files/beaut.service ~/.config/systemd/user/beaut.service
    if command -v systemctl >/dev/null 2>&1 \
       && systemctl --user daemon-reload 2>/dev/null \
       && systemctl --user enable --now beaut.service 2>/dev/null; then
      echo "beaut user service is active"
    else
      pkill -f "beaut/scripts/http_server.sh" 2>/dev/null || true
      setsid bash ~/.beaut/deploy/files/start.sh \
        > ~/.beaut/state/http.log 2>&1 < /dev/null &
      echo "server started through setsid (see state/http.log)"
    fi' || die "cannot start the server"
}

wait_for_server() {
  local attempt
  for attempt in 1 2 3 4 5; do
    curl -fsS "http://$SERVER_HOST:$HTTP_PORT/work" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

install_remote() {
  has_command ssh  || die "ssh is required"
  has_command scp  || die "scp is required"
  has_command curl || die "curl is required"

  choose_bootstrap_user
  log info "bootstrapping $SERVER_HOST through $BOOTSTRAP_USER, then $SERVICE_USER"
  bootstrap_remote
  verify_key_auth
  log info "key accepted for $SERVICE_USER@$SERVER_HOST"

  upload_tree
  init_git_repo
  publish_tree
  configure_network
  start_service

  if wait_for_server; then
    log info "server active: http://$SERVER_HOST:$HTTP_PORT"
    log info "node: curl -fsS http://$SERVER_HOST:$HTTP_PORT/node | sh"
  else
    log error "server unreachable on http://$SERVER_HOST:$HTTP_PORT (~/.beaut/state/http.log)"
    exit 1
  fi
  log info "installation complete on $SERVER_HOST (user $SERVICE_USER)"
}

# --- local mode -------------------------------------------------------------
install_local() {
  local target="${SERVICE_ROOT:-$HOME/.$SERVICE_USER}"
  mkdir -p "$target/state" "$target/shared" "$target/deploy"
  cp -a "$SCRIPTS_DIR" "$target/"
  cp -a "$FILES_DIR" "$target/deploy/"
  cp -f "$CONFIG_FILE" "$target/config.env"
  find "$target/scripts" -type f -name '*.sh' -exec chmod 755 {} +
  chmod 755 "$target/deploy/files/start.sh"
  echo "=== local installation complete in $target ==="
  echo "start: bash $target/deploy/files/start.sh"
}

if [[ $LOCAL_MODE -eq 1 ]]; then
  install_local
else
  install_remote
fi
