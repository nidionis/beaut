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
#     which applies deploy/bootstrap.sh: creates SERVICE_USER, authorizes
#     its key, installs the root-owned copy, writes the sudo grant, starts the
#     service. WireGuard is configured through the sudo grant.
#   user (--no-root): connect as SERVICE_USER with the key only, install under
#     $HOME/.beaut and start the service without any sudo; no WireGuard.
#
# Then, everything else runs as SERVICE_USER (private key, no password), inside
# $HOME/.beaut: site/ (the published tree with its builtins), state/.
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

LOCAL_TEMP_FILES=()
cleanup() {
  ((${#LOCAL_TEMP_FILES[@]} > 0)) && rm -f -- "${LOCAL_TEMP_FILES[@]}"
  return 0
}
trap cleanup EXIT

# --- identity ---------------------------------------------------------------
# The normal case is an already bootstrapped host: SERVICE_USER authenticates
# with the configured key and passwordless sudo works. Only a fresh host needs
# BOOTSTRAP_USER, which is then used as the first application identity.
service_user_is_ready() {
  as_service_user true >/dev/null 2>&1 && as_service_user 'sudo -n true' >/dev/null 2>&1
}

# --- connection as SERVICE_USER (key only, never a password) ----------------
SSH_BASE=(-o BatchMode=yes -o IdentitiesOnly=yes
          -o PreferredAuthentications=publickey -o StrictHostKeyChecking=accept-new)
if [[ "$DEBUG" -eq 1 ]]; then
  SSH_BASE+=(-o LogLevel=DEBUG3)
fi
as_service_user() { ssh -n -i "$SSH_PRIVATE_KEY" "${SSH_BASE[@]}" "$SERVICE_USER@$SERVER_HOST" "$@"; }
copy_to_service_user() { scp -i "$SSH_PRIVATE_KEY" "${SSH_BASE[@]}" "$@"; }
remote_run() { ssh -T -i "$SSH_PRIVATE_KEY" "${SSH_BASE[@]}" "$SERVICE_USER@$SERVER_HOST" 'bash -s' < "$1"; }

# --- 1. bootstrap through BOOTSTRAP_USER ------------------------------------
bootstrap_remote() {
  local public_key_b64 assignments remote_payload local_payload
  [[ -f "$SSH_PRIVATE_KEY" ]]     || die "private key not found: $SSH_PRIVATE_KEY"
  [[ -f "$SSH_PRIVATE_KEY.pub" ]] || die "public key not found: $SSH_PRIVATE_KEY.pub"

  public_key_b64="$(base64 -w0 < "$SSH_PRIVATE_KEY.pub")"
  remote_payload="/tmp/beaut-bootstrap.$$.tgz"
  local_payload="$(mktemp "${TMPDIR:-/tmp}/beaut.XXXXXX")"
  LOCAL_TEMP_FILES+=("$local_payload")
  tar -czf "$local_payload" -C "$PROJECT_ROOT" site/scripts site/deploy config.env.example

  scp "$local_payload" "$BOOTSTRAP_USER@$SERVER_HOST:$remote_payload" \
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
}

# --- 2. verify passwordless key authentication ------------------------------
verify_key_auth() {
  as_service_user true || die "key refused for $SERVICE_USER@$SERVER_HOST (authorized_keys, home permissions, StrictModes?)"
}

# --- 3. upload, then everything as SERVICE_USER -----------------------------
# The site tree carries the builtins (site/scripts, site/deploy) and the public
# content. Only the configuration files live next to it, never inside it.
upload_config() {
  copy_to_service_user "$CONFIG_FILE" "$SERVICE_USER@$SERVER_HOST:.beaut/config.env" \
    || die "cannot copy configuration"
  copy_to_service_user "$PROJECT_ROOT/config.env.example" \
    "$SERVICE_USER@$SERVER_HOST:.beaut/config.env.example" \
    || die "cannot copy the configuration schema"
}

# Upload the whole site tree. A top-level `site/<name>` that contains .git is
# recorded as `name<TAB>remote_url` and left out of the archive: the server
# clones it (or fast-forwards it) instead. Everything else is mirrored.
upload_site() {
  local site_directory="$PROJECT_ROOT/site"
  local entry name remote_url local_payload local_repositories
  local remote_staging='.beaut/.site-staging'
  local remote_repositories='.beaut/.site-repositories.tsv'
  local -a archive_excludes=()
  local svr_upload_name=""
  svr_upload_name="${SVR_NAME:-}"
  [[ -z "$svr_upload_name" && -s "${STATE_DIR:-$PROJECT_ROOT/state}/svr_name" ]] && svr_upload_name="$(tr -d '[:space:]' < "${STATE_DIR:-$PROJECT_ROOT/state}/svr_name")"

  if [[ ! -d "$site_directory" ]]; then
    log info "no site/ directory: leaving the public tree unchanged"
    return 0
  fi

  local_payload="$(mktemp "${TMPDIR:-/tmp}/beaut.XXXXXX")"
  local_repositories="$(mktemp "${TMPDIR:-/tmp}/beaut.XXXXXX")"
  LOCAL_TEMP_FILES+=("$local_payload" "$local_repositories")

  for entry in "$site_directory"/*; do
    [[ -e "$entry" ]] || continue
    name="$(basename -- "$entry")"
    # Exclude the generated SVR tree link/dir (managed by svr.sh).
    if [[ -n "$svr_upload_name" && "$name" == "$svr_upload_name" ]]; then
      archive_excludes+=("--exclude=./$name")
      continue
    fi
    [[ -e "$entry/.git" ]] || continue
    # A worktree has .git as a file (gitdir pointer) - it is the hidden svr tree,
    # generated locally and managed on the server; never upload it.
    if [[ -f "$entry/.git" ]]; then
      archive_excludes+=("--exclude=./$name")
      continue
    fi
    has_command git || die "git is required for site repository: $name"
    remote_url="$(git -C "$entry" config --get remote.origin.url 2>/dev/null || true)"
    [[ -n "$remote_url" ]] || die "site repository $name has no origin remote"
    printf '%s\t%s\n' "$name" "$remote_url" >> "$local_repositories"
    archive_excludes+=("--exclude=./$name")
  done

  tar -czf "$local_payload" --exclude='.git' "${archive_excludes[@]}" \
    -C "$site_directory" . || die "cannot archive site/"

  as_service_user "rm -rf ~/$remote_staging && mkdir -p ~/$remote_staging" \
    || die "cannot prepare the remote site staging directory"
  copy_to_service_user "$local_payload" "$SERVICE_USER@$SERVER_HOST:$remote_staging/payload.tgz" \
    || die "cannot upload the site archive"
  copy_to_service_user "$local_repositories" "$SERVICE_USER@$SERVER_HOST:$remote_repositories" \
    || die "cannot upload the site repository list"
  as_service_user "set -e
    cd ~/$remote_staging
    tar xzf payload.tgz
    rm -f payload.tgz
    cd ~/.beaut
    bash ~/$remote_staging/deploy/sync_site.sh ~/$remote_staging ~/$remote_repositories
    rm -rf ~/$remote_staging ~/$remote_repositories" \
    || die "cannot apply the site tree"
}

# --- 4. HTTP tree: the path mirrors the file --------------------------------
# /node is published as a self-contained artifact rendered ON THE SERVER from
# the deployed site scripts and config: no local client file is uploaded and
# `curl .../node | sh` works with zero client files.
# /join is not published; site/scripts/wireguard_join.sh stays a repo command.
publish_tree() {
  case "$SERVER_HOST" in
    ''|*[!A-Za-z0-9._:-]*) die "invalid SERVER_HOST: $SERVER_HOST" ;;
  esac
  case "$HTTP_PORT" in
    ''|*[!0-9]*) die "invalid HTTP_PORT: $HTTP_PORT" ;;
  esac

  as_service_user "set -e
    cd ~/.beaut/site
    mkdir -p node
    bash scripts/build_published_node.sh '$SERVER_HOST' '$HTTP_PORT' > node/DEFAULT.sh
    chmod -R a+rX ~/.beaut/site" || die "cannot publish the HTTP tree"
}

# Refresh the root-owned privileged copy without re-running bootstrap. The
# service user already has sudo, so this does not widen its rights; it keeps
# network.sh/wireguard.sh current between deploys.
install_privileged_scripts() {
  as_service_user "sudo -n env SERVICE_HOME=\"\$HOME\" bash ~/.beaut/site/deploy/install_privileged.sh" \
    || die "cannot refresh the privileged scripts"
}

# --- 4b. local identities and the hidden personal tree ----------------------
initialize_identity() {
  if [[ "$INSTALL_MODE" == "root" ]]; then
    as_service_user 'cd ~/.beaut && bash site/scripts/device.sh init "$(hostname 2>/dev/null || printf server)"' \
      || die "cannot initialize the server device identity"
  else
    log info "no-root mode: skipping the server device identity (no WireGuard)"
  fi
  as_service_user 'cd ~/.beaut && bash site/scripts/svr.sh init' \
    || die "cannot initialize the personal tree"
  as_service_user 'cd ~/.beaut && bash site/scripts/svr.sh install' \
    || die "cannot install the journal commands"
}

# --- 5. privileged resources through the sudo grant -------------------------
configure_network() {
  as_service_user "if command -v wg >/dev/null 2>&1; then
            sudo -n bash /usr/local/lib/beaut/site/scripts/network.sh setup || echo 'warning: network not configured' >&2
            sudo -n bash /usr/local/lib/beaut/site/scripts/network.sh sync-peers || echo 'warning: peers not synchronized' >&2
          else
            echo 'warning: wireguard missing, network skipped' >&2
          fi" || true
}

wait_for_server() {
  local attempt
  for attempt in {1..10}; do
    curl -fsS "http://$SERVER_HOST:$HTTP_PORT/work" >/dev/null 2>&1 && return 0
    sleep 1
  done
  log error "server unreachable on http://$SERVER_HOST:$HTTP_PORT (~/.beaut/state/http.log, journal: systemctl --user -u beaut.service)"
  as_service_user 'systemctl --user status beaut.service --no-pager -l 2>&1; journalctl --user -u beaut.service -n 40 --no-pager 2>&1' >/dev/null 2>&1 || true
  return 1
}

install_server() {
  local required_command
  for required_command in ssh scp curl tar; do
    has_command "$required_command" || die "$required_command is required"
  done

  if [[ "$INSTALL_MODE" == "root" ]]; then
    if service_user_is_ready; then
      log info "identity detected: $SERVICE_USER@$SERVER_HOST (key + sudo)"
    else
      BOOTSTRAP_USER="${BOOTSTRAP_USER:-root}"
      log info "bootstrapping $SERVER_HOST through $BOOTSTRAP_USER, then $SERVICE_USER"
      bootstrap_remote
    fi
  else
    log info "no-root mode: installing $SERVER_HOST as $SERVICE_USER without sudo"
  fi
  verify_key_auth
  log info "key accepted for $SERVICE_USER@$SERVER_HOST"

  upload_config
  upload_site
  if [[ "$INSTALL_MODE" == "root" ]]; then
    install_privileged_scripts
  fi
  publish_tree
  initialize_identity

  if [[ "$INSTALL_MODE" == "root" ]]; then
    configure_network
  else
    log info "no-root mode: skipping network/WireGuard configuration (no sudo)"
  fi

  remote_run "$FILES_DIR/remote_install.sh"
  wait_for_server || exit 1
  log info "server active: http://$SERVER_HOST:$HTTP_PORT"
  log info "node: curl -fsS http://$SERVER_HOST:$HTTP_PORT/node | sh"
  log info "installation complete on $SERVER_HOST (user $SERVICE_USER)"
}

install_server
