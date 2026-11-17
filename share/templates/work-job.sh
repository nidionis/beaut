# beaut work: job @JOB@
(
  set -eu
  job=@JOB@
  archive=@ARCHIVE@
  container_url=@CONTAINER_URL@
  restore_url=@RESTORE_URL@
  backup_address=@BACKUP_ADDRESS@
  backup_port=@BACKUP_PORT@
  state="${BEAUT_STATE_DIR:?}"
  containers="${BEAUT_CONTAINER_DIR:?}"
  docker_cmd="${BEAUT_DOCKER_CMD:-docker}"
  jobdir="$containers/$job"

  mkdir -p "$containers" "$state/assign" "$state/marks"
  printf '%s %s\n' "$backup_address" "$backup_port" >"$state/assign/$job"

  if [ -f "$state/marks/$job.done" ] &&
    [ "$(cat "$state/marks/$job.done")" = "$archive" ]; then
    exit 0
  fi
  if [ -f "$state/marks/$job.running" ] &&
    [ "$(cat "$state/marks/$job.running")" = "$archive" ] &&
    [ -n "$($docker_cmd ps -q --filter "name=beaut-$job" --filter "status=running" 2>/dev/null)" ]; then
    exit 0
  fi

  rm -f "$state/marks/$job.running" "$state/marks/$job.done" "$state/marks/$job.failed"

  if [ -n "$restore_url" ]; then
    if ! curl -fsS --noproxy '*' --connect-timeout 10 --max-time 600 \
      "$restore_url" | tar -xzf - -C "$containers"; then
      printf 'beaut: no usable snapshot for %s; starting from the project archive\n' "$job" >&2
    fi
  fi

  if [ ! -f "$jobdir/.archive" ] ||
    [ "$(cat "$jobdir/.archive" 2>/dev/null || true)" != "$archive" ]; then
    curl -fsS --noproxy '*' --connect-timeout 10 --max-time 600 \
      "$container_url" | tar -xzf - -C "$containers"
    printf '%s\n' "$archive" >"$jobdir/.archive"
  fi

  cd -- "$jobdir"

  if [ -f compose.yaml ] || [ -f docker-compose.yml ]; then
    if $docker_cmd compose version >/dev/null 2>&1; then
      $docker_cmd compose -p "beaut-$job" up -d --build
    else
      docker-compose -p "beaut-$job" up -d --build
    fi
  elif [ -f Dockerfile ]; then
    if [ -f beaut.env ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          ""|\#*) continue ;;
        esac
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
          RUN_MODE) run_mode="$value" ;;
          PORTS) ports="$value" ;;
          ENVS) envs="$value" ;;
          COMMAND) command="$value" ;;
        esac
      done <beaut.env
    fi
    args=""
    for port in ${ports:-}; do
      args="$args -p $port"
    done
    for env in ${envs:-}; do
      args="$args -e $env"
    done
    image="beaut-$job"
    $docker_cmd build -t "$image" .
    if [ "${run_mode:-service}" = once ]; then
      # shellcheck disable=SC2086
      $docker_cmd run --rm $args "$image" ${command:-}
      rm -f "$state/marks/$job.running"
      printf '%s\n' "$archive" >"$state/marks/$job.done"
      rm -f "$state/assign/$job"
      exit 0
    fi
    $docker_cmd rm -f "beaut-$job" >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    $docker_cmd run -d --name "beaut-$job" \
      --label "beaut.job=$job" --restart unless-stopped \
      $args "$image" ${command:-}
  else
    printf 'beaut: job %s has no compose.yaml or Dockerfile\n' "$job" >&2
    exit 1
  fi

  printf '%s\n' "$archive" >"$state/marks/$job.running"
)
