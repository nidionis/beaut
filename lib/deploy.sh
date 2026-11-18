# deploy.sh - pack the tree, install it over SSH and restart user units.
#
# Deploy scripts are argument-free. They read conf/conf.env, deploy as
# $ADMIN_USER and never touch state, logs, snapshots or key files.

deploy_quote() { printf '%q' "$1"; }

# deploy_ssh_opts [first] - set DEPLOY_SSH_OPTS from SSH_OPTS and the node key.
# "first" drops BatchMode=yes so the first connection can use a password.
deploy_ssh_opts() {
  local mode="${1:-}" i=0
  local -a opts filtered
  read -r -a opts <<<"$SSH_OPTS"

  if [[ "$mode" == first ]]; then
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
  else
    filtered=("${opts[@]}")
  fi

  [[ -f "$NODE_KEY" ]] && filtered+=(-i "$NODE_KEY")
  DEPLOY_SSH_OPTS=("${filtered[@]}")
}

deploy_ssh() {
  local target="$1"
  shift
  deploy_ssh_opts
  ssh "${DEPLOY_SSH_OPTS[@]}" "$target" "$@"
}

# deploy_first_ssh USER TARGET PASSWORD COMMAND... - connect before the node key
# is trusted. PASSWORD, when set, is passed to sshpass through the environment.
deploy_first_ssh() {
  local user="$1" target="$2" password="$3"
  shift 3
  deploy_ssh_opts first
  if [[ -n "$password" ]]; then
    SSHPASS="$password" sshpass -e ssh "${DEPLOY_SSH_OPTS[@]}" "$user@$target" "$@"
  else
    ssh "${DEPLOY_SSH_OPTS[@]}" "$user@$target" "$@"
  fi
}

# deploy_role_address ROLE [WORKER_FALLBACK] - print the explicit address used
# for ROLE. An empty result means the caller must explain what is missing.
deploy_role_address() {
  local role="$1" fallback="${2:-}"
  is_role "$role" || return 1
  if [[ "$role" == hub ]]; then
    printf '%s\n' "$HUB"
  else
    printf '%s\n' "${WORKER_ADDRESS:-$fallback}"
  fi
}

deploy_hub_target() {
  printf '%s@%s\n' "${SSH_USER:-$ADMIN_USER}" "$HUB"
}

deploy_worker_target() {
  [[ -n "$WORKER_TARGET" ]] || die "WORKER_TARGET is empty"
  if [[ "$WORKER_TARGET" == *@* ]]; then
    printf '%s\n' "$WORKER_TARGET"
  else
    printf '%s@%s\n' "${SSH_USER:-$ADMIN_USER}" "$WORKER_TARGET"
  fi
}

# deploy_remote_paths TARGET - resolve the paths used on the remote node.
#
# ROOT defaults to $HOME/.beaut. When that default is in use, the remote path
# is derived from the remote account's home so nodes with different homes still
# agree. An explicit ROOT is used unchanged on every node.
deploy_remote_paths() {
  local target="$1" remote_home
  [[ -n "$target" ]] || die "deploy_remote_paths needs a target"
  remote_home="$(deploy_ssh "$target" 'printf %s "$HOME"')" ||
    die "cannot query the home directory on $target"
  [[ -n "$remote_home" ]] || die "empty home directory on $target"

  if [[ "$ROOT" == "$HOME/.beaut" ]]; then
    DEPLOY_ROOT="$remote_home/.beaut"
  else
    DEPLOY_ROOT="$ROOT"
  fi

  if [[ "$APP_DIR" == "$ROOT/app" ]]; then
    DEPLOY_APP_DIR="$DEPLOY_ROOT/app"
  else
    DEPLOY_APP_DIR="$APP_DIR"
  fi

  [[ -n "$DEPLOY_ROOT" && "$DEPLOY_ROOT" != / ]] || die "refusing unsafe ROOT: $DEPLOY_ROOT"
  [[ -n "$DEPLOY_APP_DIR" && "$DEPLOY_APP_DIR" != / ]] ||
    die "refusing unsafe APP_DIR: $DEPLOY_APP_DIR"
  case "$DEPLOY_ROOT/" in
    "$DEPLOY_APP_DIR"/*)
      die "APP_DIR must not contain ROOT: $DEPLOY_APP_DIR contains $DEPLOY_ROOT"
      ;;
  esac

  DEPLOY_CONF_DIR="$DEPLOY_ROOT/conf"
  DEPLOY_CONFIG="$DEPLOY_CONF_DIR/conf.env"
  DEPLOY_NODE_ENV="$DEPLOY_CONF_DIR/node.env"
}

deploy_sync_tree() {
  local target="$1" remote_app
  [[ "$BEAUT_ROOT" != "$DEPLOY_APP_DIR" ]] ||
    die "refusing to replace the source tree: $BEAUT_ROOT"
  remote_app="$(deploy_quote "$DEPLOY_APP_DIR")"
  tar -C "$BEAUT_ROOT" -czf - \
    --exclude='./.git' --exclude='./.git/*' \
    --exclude='./context' --exclude='./context/*' \
    --exclude='./conf/conf.env' --exclude='./conf/node.env' \
    --exclude='./conf/keys' --exclude='./conf/keys/*' \
    --exclude='./conf/workers' --exclude='./conf/workers/*' \
    --exclude='./tests/.build' --exclude='./tests/.build/*' \
    . |
    deploy_ssh "$target" \
      "rm -rf -- $remote_app && mkdir -p -- $remote_app && tar -xzf - -C $remote_app" ||
    die "cannot install tree on $target"
}

deploy_write_config() {
  local target="$1" file
  file="$(deploy_quote "$DEPLOY_CONFIG")"
  deploy_ssh "$target" \
    "umask 077; mkdir -p -- $(deploy_quote "$DEPLOY_CONF_DIR"); cat > $file" \
    <"$BEAUT_CONFIG" || die "cannot install $DEPLOY_CONFIG on $target"
}

deploy_write_node() {
  local role="$1" address="$2" target="$3" file
  file="$(deploy_quote "$DEPLOY_NODE_ENV")"
  {
    printf 'NODE_ROLE=%s\n' "$(sh_quote "$role")"
    printf 'NODE_ADDRESS=%s\n' "$(sh_quote "$address")"
    printf 'HUB=%s\n' "$(sh_quote "$HUB")"
    printf 'WORKER_PORT=%s\n' "$(sh_quote "$WORKER_PORT")"
  } | deploy_ssh "$target" "umask 077; cat > $file" ||
    die "cannot install $DEPLOY_NODE_ENV on $target"
}

deploy_install_unit() {
  local target="$1" template="$2" unit="$3"
  render_template "$BEAUT_ROOT/services/$template" \
    APP_DIR "$DEPLOY_APP_DIR" \
    CONFIG "$DEPLOY_CONFIG" \
    NODE_ENV "$DEPLOY_NODE_ENV" |
    deploy_ssh "$target" \
      "umask 022; mkdir -p -- \"\$HOME/.config/systemd/user\"; cat > \"\$HOME/.config/systemd/user/$(deploy_quote "$unit")\"" ||
    die "cannot install $unit on $target"
}

deploy_restart() {
  local target="$1"
  shift
  local units="$*" unit
  deploy_ssh "$target" \
    "export XDG_RUNTIME_DIR=\"\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}\";
     loginctl enable-linger \"\$(id -un)\" >/dev/null 2>&1 || true;
     systemctl --user daemon-reload &&
     systemctl --user enable --now $units &&
     systemctl --user restart $units" ||
    die "cannot restart units on $target"
  for unit in $units; do
    if ! deploy_ssh "$target" \
      "export XDG_RUNTIME_DIR=\"\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}\";
       systemctl --user is-active --quiet $(deploy_quote "$unit")"; then
      deploy_ssh "$target" \
        "export XDG_RUNTIME_DIR=\"\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}\";
         journalctl --user -u $(deploy_quote "$unit") -n 40 --no-pager" >&2 || true
      die "unit is not active: $unit"
    fi
  done
}

deploy_node() {
  local role="$1" target address
  is_role "$role" || die "unknown deploy role: $role"

  if [[ "$role" == hub ]]; then
    target="$(deploy_hub_target)"
  else
    target="$(deploy_worker_target)"
  fi
  address="$(deploy_role_address "$role")"
  if [[ "$role" == worker && -z "$address" ]]; then
    die "WORKER_ADDRESS is empty (set the worker's explicit address)"
  fi

  [[ -f "$BEAUT_CONFIG" ]] || die "missing config: $BEAUT_CONFIG"
  deploy_remote_paths "$target"
  deploy_sync_tree "$target"
  deploy_write_config "$target"
  deploy_write_node "$role" "$address" "$target"

  if [[ "$role" == hub ]]; then
    deploy_install_unit "$target" hub.service beaut-hub.service
    deploy_install_unit "$target" work.service beaut-work.service
    deploy_restart "$target" beaut-hub.service beaut-work.service
  else
    deploy_install_unit "$target" worker.service beaut-worker.service
    deploy_restart "$target" beaut-worker.service
  fi
  printf 'deploy: %s installed on %s (%s)\n' "$role" "$target" "$address"
}
