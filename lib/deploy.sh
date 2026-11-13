#!/usr/bin/env bash
# deploy.sh - installation over key/agent SSH and SFTP, or directly for a node
# that is this machine.
#
# Remote deployments use no password authentication: files are transferred with
# SFTP and SSH is only used to run the privileged installer and cleanup
# commands.  A target whose host resolves to a local address is staged from
# BEAUT_ROOT and installed in place, so a single-machine setup needs no SSH
# account.

deploy_log() { beaut_log "$*"; }

# Read an optional per-worker override such as BEAUT_WORKER_w1_CPUS.
deploy_worker_override() {
  local name="$1" suffix="$2" var key
  var="$(beaut_sanitize_var "$name")"
  key="BEAUT_WORKER_${var}_${suffix}"
  printf '%s' "${!key:-}"
}

deploy_ssh_options() {
  printf '%s\n' \
    -o BatchMode=yes \
    -o PreferredAuthentications=publickey \
    -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3
}

# Every node accepts SSH from the same service account.  Port, key and proxy
# settings come from ~/.ssh/config; the account is prepared by
# scripts/bootstrap-node.sh and has passwordless sudo.
deploy_destination() {
  printf '%s@%s' "$BEAUT_NAME" "$1"
}

deploy_ssh() {
  local host="$1" command="$2"
  local -a args=()
  mapfile -t args < <(deploy_ssh_options)
  ssh "${args[@]}" "$(deploy_destination "$host")" "$command"
}

# Return success when a deployment target is this machine.  Matching the
# configured address against the local interface list avoids treating the
# LAN address of the local host as a remote SSH destination.
deploy_host_is_local() {
  local host="${1:-}" addr local_name
  local -a local_addrs=()
  [[ -n "$host" ]] || return 1
  case "$host" in
    localhost|localhost.localdomain|::1|\[::1\]|0:0:0:0:0:0:0:1) return 0 ;;
    127.*) [[ "$host" =~ ^127(\.[0-9]{1,3}){3}$ ]] && return 0 ;;
  esac
  for local_name in "$(hostname 2>/dev/null || true)" \
    "$(hostname -s 2>/dev/null || true)" \
    "$(hostname -f 2>/dev/null || true)"; do
    [[ -n "$local_name" && "$host" == "$local_name" ]] && return 0
  done
  read -r -a local_addrs <<<"$(hostname -I 2>/dev/null || true)"
  local_addrs+=(127.0.0.1 ::1)
  for addr in "${local_addrs[@]}"; do
    [[ "$host" == "$addr" ]] && return 0
  done
  while read -r addr; do
    [[ -n "$addr" ]] || continue
    for local_name in "${local_addrs[@]}"; do
      [[ "$addr" == "$local_name" ]] && return 0
    done
  done < <(getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u)
  return 1
}

deploy_sftp_quote() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  printf '"%s"' "${value//\"/\\\"}"
}

deploy_sftp_put() {
  local host="$1" local_file="$2" remote_file="$3"
  local -a args=()
  local batch
  mapfile -t args < <(deploy_ssh_options)
  batch="$(mktemp "${TMPDIR:-/tmp}/beaut-sftp.XXXXXX")" || return 1
  printf 'put %s %s\n' \
    "$(deploy_sftp_quote "$local_file")" \
    "$(deploy_sftp_quote "$remote_file")" > "$batch" || {
    rm -f -- "$batch"
    return 1
  }
  sftp -q -b "$batch" "${args[@]}" "$(deploy_destination "$host")" >/dev/null
  local result=$?
  rm -f -- "$batch"
  return "$result"
}

deploy_pack_tree() {
  local archive="$1"
  tar -C "$BEAUT_ROOT" -czf "$archive" \
    --exclude='./.git' --exclude='./.ssh' --exclude='./.idea' \
    --exclude='./.junie' --exclude='./context' --exclude='./state' \
    --exclude='./store' --exclude='./.svr' --exclude='./beaut.conf' \
    --exclude='./tests/.build' --exclude='*.lock' --exclude='*.swp' \
    --exclude='*.tmp' .
}

deploy_stage_tree_local() {
  local local_dir archive
  local_dir="$(mktemp -d "${TMPDIR:-/tmp}/beaut-deploy.XXXXXX")" || return 1
  archive="$(mktemp "${TMPDIR:-/tmp}/beaut-tree.XXXXXX.tar.gz")" || {
    rmdir -- "$local_dir"
    return 1
  }
  deploy_log "staging source in $local_dir"
  if ! deploy_pack_tree "$archive"; then
    beaut_warn "source archive failed at $BEAUT_ROOT"
  elif ! tar -xzf "$archive" -C "$local_dir"; then
    beaut_warn "source staging failed in $local_dir"
  else
    rm -f -- "$archive"
    printf '%s\n' "$local_dir"
    return 0
  fi
  rm -f -- "$archive"
  rm -rf -- "$local_dir"
  return 1
}

deploy_upload_tree() {
  local host="$1"
  local remote_dir="/tmp/beaut-deploy.$$.$RANDOM"
  local remote_archive="${remote_dir}.tar.gz"
  local archive result=0
  archive="$(mktemp "${TMPDIR:-/tmp}/beaut-tree.XXXXXX.tar.gz")" || return 1
  deploy_log "uploading source to ${host}:${remote_dir}"
  if ! deploy_pack_tree "$archive"; then
    beaut_warn "source archive failed at $BEAUT_ROOT"
    result=1
  elif ! deploy_sftp_put "$host" "$archive" "$remote_archive"; then
    beaut_warn "source upload failed for $host"
    result=1
  elif ! deploy_ssh "$host" \
      "mkdir -p '$remote_dir' && tar -xzf '$remote_archive' -C '$remote_dir' && rm -f '$remote_archive'"; then
    beaut_warn "source extract failed on $host"
    result=1
  fi
  rm -f -- "$archive"
  (( result == 0 )) || return 1
  printf '%s\n' "$remote_dir"
}

deploy_run_root() {
  local host="$1" remote_script="$2"
  local command="bash '$remote_script'"
  deploy_ssh "$host" "
    if [ \"\$(id -u)\" -eq 0 ]; then exec $command; fi
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      exec sudo -n $command
    fi
    echo 'error: SSH user needs passwordless sudo' >&2
    exit 1"
}

deploy_run_root_local() {
  local script="$1"
  if [[ "$(id -u)" -eq 0 ]]; then
    bash "$script"
    return
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    beaut_warn "local install requires root and sudo is not available"
    return 1
  fi
  if sudo -n true 2>/dev/null; then
    sudo -n bash "$script"
    return
  fi
  if [[ -t 0 ]]; then
    deploy_log "local install requires root; requesting sudo"
    sudo bash "$script"
    return
  fi
  beaut_warn "local install requires passwordless sudo or an interactive terminal"
  return 1
}

deploy_render_worker_config() {
  local name="$1" advertise_host="$2" worker_port="$3" output="$4"
  local hub_url="$BEAUT_PUBLIC_URL" hub_host scheme
  local cpus memory disk tags max_sessions
  if [[ "$hub_url" == *"://127."* || "$hub_url" == *"://localhost"* \
        || "$hub_url" == *"://[::1]"* ]]; then
    scheme="${hub_url%%://*}"
    hub_host="${BEAUT_HUB_ADVERTISE:-$(beaut_url_host "$BEAUT_HUB_URL")}"
    hub_url="${scheme}://${hub_host}:${BEAUT_HUB_PORT}"
  fi
  cpus="$(deploy_worker_override "$name" CPUS)"
  [[ -n "$cpus" ]] || cpus="$BEAUT_WORKER_CPUS"
  memory="$(deploy_worker_override "$name" MEMORY_MB)"
  [[ -n "$memory" ]] || memory="$BEAUT_WORKER_MEMORY_MB"
  disk="$(deploy_worker_override "$name" DISK_MB)"
  [[ -n "$disk" ]] || disk="$BEAUT_WORKER_DISK_MB"
  tags="$(deploy_worker_override "$name" TAGS)"
  [[ -n "$tags" ]] || tags="$BEAUT_WORKER_TAGS"
  max_sessions="$(deploy_worker_override "$name" MAX_SESSIONS)"
  [[ -n "$max_sessions" ]] || max_sessions="$BEAUT_WORKER_MAX_SESSIONS"
  {
    printf '# generated worker config for %s\n' "$name"
    printf 'BEAUT_NAME=%q\n' "$BEAUT_NAME"
    printf 'BEAUT_VERSION=%q\n' "$BEAUT_VERSION"
    printf 'BEAUT_USER=%q\n' "$BEAUT_USER"
    printf 'BEAUT_GROUP=%q\n' "$BEAUT_GROUP"
    printf 'BEAUT_HOME=%q\n' "$BEAUT_HOME"
    printf 'BEAUT_CONFIG_DIR=%q\n' "$BEAUT_CONFIG_DIR"
    printf 'BEAUT_HUB_NAME=%q\n' "$BEAUT_HUB_NAME"
    printf 'BEAUT_HUB_URL=%q\n' "$hub_url"
    printf 'BEAUT_PUBLIC_URL=%q\n' "$hub_url"
    printf 'BEAUT_HUB_DOMAIN=%q\n' "$BEAUT_HUB_DOMAIN"
    printf 'BEAUT_WORKER_NAME=%q\n' "$name"
    printf 'BEAUT_NODE_NAME=%q\n' "$name"
    printf 'BEAUT_WORKER_BIND=%q\n' "$BEAUT_WORKER_BIND"
    printf 'BEAUT_WORKER_PORT=%q\n' "$worker_port"
    printf 'BEAUT_WORKER_ADVERTISE=%q\n' "$advertise_host"
    printf 'BEAUT_WORKER_CPUS=%q\n' "$cpus"
    printf 'BEAUT_WORKER_MEMORY_MB=%q\n' "$memory"
    printf 'BEAUT_WORKER_DISK_MB=%q\n' "$disk"
    printf 'BEAUT_WORKER_TAGS=%q\n' "$tags"
    printf 'BEAUT_WORKER_MAX_SESSIONS=%q\n' "$max_sessions"
    printf 'BEAUT_DOCKER=%q\n' "$BEAUT_DOCKER"
    printf 'BEAUT_SESSION_PORT=%q\n' "$BEAUT_SESSION_PORT"
    printf 'BEAUT_SESSION_PROTOCOL=%q\n' "$BEAUT_SESSION_PROTOCOL"
    printf 'BEAUT_SESSION_CPUS=%q\n' "$BEAUT_SESSION_CPUS"
    printf 'BEAUT_SESSION_MEMORY_MB=%q\n' "$BEAUT_SESSION_MEMORY_MB"
    printf 'BEAUT_SESSION_SNAPSHOT_ON_STOP=%q\n' "$BEAUT_SESSION_SNAPSHOT_ON_STOP"
    printf 'BEAUT_MIN_COPIES=%q\n' "$BEAUT_MIN_COPIES"
    printf 'BEAUT_STRICT_COPIES=%q\n' "$BEAUT_STRICT_COPIES"
    printf 'BEAUT_CHUNK_SIZE=%q\n' "$BEAUT_CHUNK_SIZE"
    printf 'BEAUT_MAX_BODY=%q\n' "$BEAUT_MAX_BODY"
    printf 'BEAUT_WORKERS=()\n'
    printf 'BEAUT_ROUTES=()\n'
  } > "$output"
  chmod 600 "$output"
}

deploy_install_node() {
  local role="$1" name="$2" ssh_host="$3" advertise_host="$4" worker_port="$5"
  local remote_dir config_file remote_name remote_script remote_script_name result=0
  local local_install=0 var
  [[ -n "$ssh_host" ]] || {
    beaut_warn "host is required for $role $name"
    return 2
  }
  if deploy_host_is_local "$ssh_host"; then
    local_install=1
    deploy_log "deploying $role ${name} locally on ${ssh_host}"
    remote_dir="$(deploy_stage_tree_local)" || {
      beaut_warn "source staging failed for $role $name"
      return 1
    }
  else
    deploy_log "deploying $role ${name} to $(deploy_destination "$ssh_host")"
    remote_dir="$(deploy_upload_tree "$ssh_host")" || {
      beaut_warn "source upload failed for $role $name"
      return 1
    }
  fi

  config_file="$(mktemp "${TMPDIR:-/tmp}/beaut-config.XXXXXX")" || {
    (( local_install )) && rm -rf -- "$remote_dir"
    return 1
  }
  if [[ "$role" == "hub" ]]; then
    cp -- "$BEAUT_CONFIG" "$config_file" || {
      rm -f -- "$config_file"
      (( local_install )) && rm -rf -- "$remote_dir"
      return 1
    }
  else
    deploy_render_worker_config "$name" "$advertise_host" "$worker_port" \
      "$config_file" || {
      rm -f -- "$config_file"
      (( local_install )) && rm -rf -- "$remote_dir"
      return 1
    }
  fi

  remote_script="$(mktemp "${TMPDIR:-/tmp}/beaut-install.XXXXXX")" || {
    rm -f -- "$config_file"
    (( local_install )) && rm -rf -- "$remote_dir"
    return 1
  }
  if (( local_install )); then
    # The installer reads both paths directly; no upload or cleanup is needed.
    remote_name="$config_file"
    remote_script_name="$remote_script"
  else
    remote_name="/tmp/beaut-config.$$.$RANDOM.conf"
    remote_script_name="/tmp/beaut-run.$$.$RANDOM.sh"
    if ! deploy_sftp_put "$ssh_host" "$config_file" "$remote_name"; then
      beaut_warn "config upload failed for $role $name"
      result=1
    fi
  fi
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export BEAUT_NAME=%q\n' "$BEAUT_NAME"
    printf 'export BEAUT_VERSION=%q\n' "$BEAUT_VERSION"
    printf 'export BEAUT_USER=%q\n' "$BEAUT_USER"
    printf 'export BEAUT_GROUP=%q\n' "$BEAUT_GROUP"
    printf 'export BEAUT_INSTALL_SRC=%q\n' "$remote_dir"
    printf 'export BEAUT_INSTALL_CONFIG=%q\n' "$remote_name"
    printf 'export BEAUT_INSTALL_ROLE=%q\n' "$role"
    printf 'export BEAUT_INSTALL_NAME=%q\n' "$name"
    printf 'export BEAUT_INSTALL_HOST=%q\n' "$ssh_host"
    for var in BEAUT_INSTALL_HOME BEAUT_INSTALL_CONFIG_DIR \
      BEAUT_INSTALL_STATE_DIR BEAUT_INSTALL_STORE_DIR BEAUT_INSTALL_LOG_DIR \
      BEAUT_INSTALL_DEST BEAUT_INSTALL_BIN BEAUT_INSTALL_DEPS \
      BEAUT_INSTALL_DOCKER BEAUT_ENABLE_ROUTER; do
      printf 'export %s=%q\n' "$var" "${!var:-}"
    done
    printf 'exec bash %q/scripts/install.sh\n' "$remote_dir"
  } > "$remote_script"
  chmod 700 "$remote_script"

  if (( ! local_install && result == 0 )) \
     && ! deploy_sftp_put "$ssh_host" "$remote_script" "$remote_script_name"; then
    beaut_warn "installer upload failed for $role $name"
    result=1
  fi

  if (( result == 0 )); then
    if (( local_install )); then
      deploy_run_root_local "$remote_script_name"
    else
      deploy_run_root "$ssh_host" "$remote_script_name"
    fi || {
      beaut_warn "$role $name install failed"
      result=1
    }
  fi
  if (( result == 0 )); then
    beaut_log "$role $name installed"
  fi

  if (( local_install )); then
    rm -rf -- "$remote_dir"
  else
    deploy_ssh "$ssh_host" \
      "rm -rf -- '$remote_dir' '$remote_name' '$remote_script_name'" \
      >/dev/null 2>&1 || true
  fi
  rm -f -- "$config_file" "$remote_script"
  return "$result"
}

deploy_command() {
  local target="${1:-}"
  case "$target" in
    all)
      deploy_hub || return 1
      local row name host port hub weight
      while IFS='|' read -r name host port hub weight; do
        [[ -n "$name" ]] || continue
        deploy_worker "$name" || return 1
      done < <(worker_rows)
      ;;
    hub) deploy_hub ;;
    worker)
      [[ -n "${2:-}" ]] || { beaut_warn "usage: beaut install worker NAME"; return 2; }
      deploy_worker "$2"
      ;;
    *) beaut_warn "usage: beaut install hub|worker NAME|all"; return 2 ;;
  esac
}

deploy_hub() {
  local host
  host="$(beaut_url_host "$BEAUT_HUB_URL")"
  [[ -n "$host" ]] || {
    beaut_warn "cannot derive an SSH host from BEAUT_HUB_URL: ${BEAUT_HUB_URL:-<unset>}"
    return 2
  }
  deploy_install_node hub "$BEAUT_HUB_NAME" "$host" "" ""
}

deploy_worker() {
  local name="$1" row host port hub weight
  row="$(worker_find "$name")" || { beaut_warn "unknown worker: $name"; return 1; }
  IFS='|' read -r _ host port hub weight <<<"$row"
  deploy_install_node worker "$name" "$host" "$host" "$port"
}
