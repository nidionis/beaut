#!/usr/bin/env bash
# fake-docker.sh - minimal Docker CLI shim used by the integration tests.
# It keeps container metadata in $FAKE_DOCKER_STATE and never touches the
# real Docker daemon.
set -euo pipefail

state="${FAKE_DOCKER_STATE:-/tmp/beaut-fake-docker}"
base_port="${FAKE_DOCKER_PORT_BASE:-20000}"
mkdir -p "$state/containers" "$state/images" "$state/loads"
cmd="${1:-}"
shift || true

container_file() { printf '%s/containers/%s' "$state" "$1"; }

case "$cmd" in
  version|info)
    printf 'fake docker\n'
    ;;
  run)
    name="" portspec="" image="" hostport="" count=""
    while (( $# )); do
      case "$1" in
        -d) shift ;;
        --name) name="${2:-}"; shift 2 ;;
        -p) portspec="${2:-}"; shift 2 ;;
        --label|--restart|--cpus|--memory) shift 2 ;;
        -*) shift ;;
        *)
          image="$1"
          shift
          break
          ;;
      esac
    done
    if [[ -z "$name" || -z "$image" ]]; then
      printf 'fake docker: run needs --name and an image\n' >&2
      exit 125
    fi
    count="$(find "$state/containers" -type f 2>/dev/null | wc -l | tr -d ' ')"
    hostport=$((base_port + count + 1))
    {
      printf 'image=%s\n' "$image"
      printf 'portspec=%s\n' "$portspec"
      printf 'hostport=%s\n' "$hostport"
      printf 'status=running\n'
      printf 'command=%s\n' "$*"
    } > "$(container_file "$name")"
    printf 'fake-container-%s\n' "$name"
    ;;
  inspect)
    fmt=""
    if [[ "${1:-}" == "-f" ]]; then fmt="${2:-}"; shift 2; fi
    cname="${1:-}"
    file="$(container_file "$cname")"
    [[ -f "$file" ]] || exit 1
    case "$fmt" in
      *State.Status*) sed -n 's/^status=//p' "$file" ;;
      *Config.Image*) sed -n 's/^image=//p' "$file" ;;
      *) printf '{"Id":"fake","Name":"%s","State":{"Status":"%s"}}\n' \
           "$cname" "$(sed -n 's/^status=//p' "$file")" ;;
    esac
    ;;
  port)
    cname="${1:-}"
    file="$(container_file "$cname")"
    [[ -f "$file" ]] || exit 1
    printf '0.0.0.0:%s\n' "$(sed -n 's/^hostport=//p' "$file")"
    ;;
  stop|start)
    cname="${1:-}"
    file="$(container_file "$cname")"
    [[ -f "$file" ]] || exit 1
    newstatus=stopped
    [[ "$cmd" == "start" ]] && newstatus=running
    sed -i "s/^status=.*/status=$newstatus/" "$file"
    printf '%s\n' "$cname"
    ;;
  exec)
    cname="${1:-}"
    shift || true
    [[ -f "$(container_file "$cname")" ]] || exit 1
    printf 'exec %s\n' "$*"
    ;;
  rm)
    cname="${2:-${1:-}}"
    [[ "$cname" == "-f" ]] && cname=""
    [[ -n "$cname" ]] && rm -f "$(container_file "$cname")"
    ;;
  commit)
    cname="${1:-}"
    image="${2:-}"
    [[ -f "$(container_file "$cname")" ]] || exit 1
    printf '%s\n' "$image" > "$state/images/${image//\//_}"
    printf 'sha256:fake-commit\n'
    ;;
  save)
    image=""
    out=""
    while (( $# )); do
      case "$1" in
        -o) out="${2:-}"; shift 2 ;;
        *) image="$1"; shift ;;
      esac
    done
    [[ -n "$out" && -n "$image" && -f "$state/images/${image//\//_}" ]] || exit 1
    printf 'fake-image:%s\n' "$image" > "$state/image-name"
    tar -cf "$out" -C "$state" image-name
    ;;
  load)
    tar_file="${2:-}"
    [[ -f "$tar_file" ]] || exit 1
    tar -xf "$tar_file" -C "$state/loads"
    image="$(cat "$state/loads/image-name")"
    printf 'Loaded image: %s\n' "$image"
    ;;
  *)
    printf 'fake docker: unsupported command %s\n' "$cmd" >&2
    exit 2
    ;;
esac
