#!/usr/bin/env bash
# docker.sh - worker-side Docker session lifecycle and snapshot upload.
# Uses the docker CLI so the agent stays small and portable.

docker_bin() {
  printf '%s' "${BEAUT_DOCKER:-docker}"
}

docker_available() {
  local bin
  bin="$(docker_bin)"
  [[ -x "$bin" ]] || command -v "$bin" >/dev/null 2>&1 || return 1
  "$bin" version >/dev/null 2>&1 || "$bin" info >/dev/null 2>&1
}

docker_local_session_path() {
  local id
  id="$(beaut_sanitize_name "$1")"
  printf '%s/sessions/%s.json' "$BEAUT_STATE_DIR" "$id"
}

docker_local_session_get() {
  local path
  path="$(docker_local_session_path "$1")"
  [[ -f "$path" ]] && cat -- "$path"
}

docker_local_session_write() {
  local id="$1" json="$2"
  beaut_atomic_write "$(docker_local_session_path "$id")" "$json"
}

docker_local_session_remove() {
  rm -f -- "$(docker_local_session_path "$1")"
}

docker_container_name() {
  printf '%s%s' "$BEAUT_SESSION_CONTAINER_PREFIX" "$(beaut_sanitize_name "$1")"
}

docker_port_for() {
  local container="$1" port="$2" output
  [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 )) || {
    printf '0'
    return 0
  }
  output="$("$(docker_bin)" port "$container" "${port}/tcp" 2>/dev/null | tail -1 || true)"
  [[ -n "$output" ]] || {
    printf '0'
    return 0
  }
  printf '%s' "${output##*:}"
}

docker_session_spec() {
  local record="$1" output="$2"
  jq -c '{id,name,image,container_port,protocol,command}' <<<"$record" > "$output"
}

docker_session_run_file() {
  local spec_file="$1" force="${2:-0}" id name image container_port protocol
  local cname existing output host_port status created record command_json
  local -a args=()
  local -a command=()
  [[ -f "$spec_file" ]] || {
    jq -cn '{ok:false,error:"missing session spec"}'
    return 1
  }
  id="$(jq -r '.id // ""' "$spec_file")"
  name="$(jq -r '.name // .id' "$spec_file")"
  image="$(jq -r '.image // ""' "$spec_file")"
  container_port="$(jq -r '.container_port // 0' "$spec_file")"
  protocol="$(jq -r '.protocol // "http"' "$spec_file")"
  command_json="$(jq -c '.command // []' "$spec_file")"
  [[ "$id" =~ ^[A-Za-z0-9._-]+$ && -n "$image" && "$image" != -* ]] || {
    jq -cn --arg error "invalid session spec" '{ok:false,error:$error}'
    return 1
  }
  cname="$(docker_container_name "$id")"

  if [[ "$force" != "1" ]] && "$(docker_bin)" inspect "$cname" >/dev/null 2>&1; then
    status="$("$(docker_bin)" inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || true)"
    if [[ "$status" != "running" ]]; then
      "$(docker_bin)" start "$cname" >/dev/null 2>&1 || true
    fi
    host_port="$(docker_port_for "$cname" "$container_port")"
    existing="$(docker_local_session_get "$id" 2>/dev/null || true)"
    if [[ -n "$existing" ]]; then
      record="$(jq -c --arg ts "$(beaut_iso)" --argjson host_port "$host_port" \
        '.status="running" | .host_port=$host_port | .updated_at=$ts' <<<"$existing")"
    else
      record="$(jq -cn --arg id "$id" --arg name "$name" --arg image "$image" \
        --argjson container_port "$container_port" --arg protocol "$protocol" \
        --argjson command "$command_json" --arg container "$cname" \
        --argjson host_port "$host_port" --arg ts "$(beaut_iso)" \
        '{id:$id,name:$name,image:$image,container_port:$container_port,
          protocol:$protocol,command:$command,container:$container,
          host_port:$host_port,status:"running",snapshot:"",snapshot_image:"",
          created_at:$ts,updated_at:$ts}')"
    fi
    docker_local_session_write "$id" "$record"
    jq -cn --arg id "$id" --argjson host_port "$host_port" --arg container "$cname" \
      '{ok:true,id:$id,host_port:$host_port,container:$container}'
    return 0
  fi

  if [[ "$force" == "1" ]] && "$(docker_bin)" inspect "$cname" >/dev/null 2>&1; then
    "$(docker_bin)" rm -f "$cname" >/dev/null 2>&1 || true
  fi

  args=(run -d --name "$cname" --label "${BEAUT_NAME}.session=$id" \
    --label "${BEAUT_NAME}.managed=1" --restart no)
  [[ -n "${BEAUT_SESSION_CPUS:-}" ]] && args+=(--cpus "$BEAUT_SESSION_CPUS")
  [[ -n "${BEAUT_SESSION_MEMORY_MB:-}" ]] && args+=(--memory "${BEAUT_SESSION_MEMORY_MB}m")
  if [[ "$container_port" =~ ^[0-9]+$ ]] && (( container_port > 0 )); then
    args+=(-p "0.0.0.0::${container_port}")
  fi
  args+=("$image")
  mapfile -t command < <(jq -r '.[]?' <<<"$command_json")
  (( ${#command[@]} == 0 )) || args+=("${command[@]}")

  if ! output="$("$(docker_bin)" "${args[@]}" 2>&1)"; then
    jq -cn --arg error "$output" '{ok:false,error:$error}'
    return 1
  fi
  host_port="$(docker_port_for "$cname" "$container_port")"
  created="$(beaut_iso)"
  record="$(jq -cn --arg id "$id" --arg name "$name" --arg image "$image" \
    --argjson container_port "$container_port" --arg protocol "$protocol" \
    --argjson command "$command_json" --arg container "$cname" \
    --argjson host_port "$host_port" --arg ts "$created" \
    '{id:$id,name:$name,image:$image,container_port:$container_port,
      protocol:$protocol,command:$command,container:$container,
      host_port:$host_port,status:"running",snapshot:"",snapshot_image:"",
      created_at:$ts,updated_at:$ts}')"
  docker_local_session_write "$id" "$record"
  jq -cn --arg id "$id" --argjson host_port "$host_port" --arg container "$cname" \
    '{ok:true,id:$id,host_port:$host_port,container:$container}'
}

docker_session_status() {
  local id="$1" cname record status
  record="$(docker_local_session_get "$id")" || {
    jq -cn --arg error "unknown local session" '{ok:false,error:$error}'
    return 1
  }
  cname="$(jq -r '.container' <<<"$record")"
  status="$("$(docker_bin)" inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo missing)"
  record="$(jq -c --arg status "$status" --arg ts "$(beaut_iso)" \
    '.status=($status) | .updated_at=$ts' <<<"$record")"
  docker_local_session_write "$id" "$record"
  jq -cn --arg id "$id" --arg status "$status" --argjson host_port "$(jq -r '.host_port // 0' <<<"$record")" \
    '{ok:true,id:$id,status:$status,host_port:$host_port}'
}

docker_session_stop() {
  local id="$1" record cname
  record="$(docker_local_session_get "$id")" || {
    jq -cn --arg error "unknown local session" '{ok:false,error:$error}'
    return 1
  }
  cname="$(jq -r '.container' <<<"$record")"
  "$(docker_bin)" stop "$cname" >/dev/null 2>&1 || true
  record="$(jq -c --arg ts "$(beaut_iso)" '.status="stopped" | .updated_at=$ts' <<<"$record")"
  docker_local_session_write "$id" "$record"
  jq -cn --arg id "$id" '{ok:true,id:$id,status:"stopped"}'
}

docker_session_start() {
  local id="$1" record cname container_port host_port
  record="$(docker_local_session_get "$id")" || {
    jq -cn --arg error "unknown local session" '{ok:false,error:$error}'
    return 1
  }
  cname="$(jq -r '.container' <<<"$record")"
  container_port="$(jq -r '.container_port // 0' <<<"$record")"
  if ! "$(docker_bin)" start "$cname" >/dev/null 2>&1; then
    jq -cn --arg error "docker start failed" '{ok:false,error:$error}'
    return 1
  fi
  host_port="$(docker_port_for "$cname" "$container_port")"
  record="$(jq -c --arg ts "$(beaut_iso)" --argjson host_port "$host_port" \
    '.status="running" | .host_port=$host_port | .updated_at=$ts' <<<"$record")"
  docker_local_session_write "$id" "$record"
  jq -cn --arg id "$id" --argjson host_port "$host_port" '{ok:true,id:$id,host_port:$host_port}'
}

docker_session_rm() {
  local id="$1" record cname
  record="$(docker_local_session_get "$id" 2>/dev/null || true)"
  if [[ -n "$record" ]]; then
    cname="$(jq -r '.container' <<<"$record")"
    "$(docker_bin)" rm -f "$cname" >/dev/null 2>&1 || true
  fi
  docker_local_session_remove "$id"
  jq -cn --arg id "$id" '{ok:true,id:$id,removed:true}'
}

docker_session_exec() {
  local id="$1" command_json="${2:-[]}" record cname output result
  record="$(docker_local_session_get "$id")" || {
    jq -cn --arg error "unknown local session" '{ok:false,error:$error}'
    return 1
  }
  cname="$(jq -r '.container' <<<"$record")"
  local -a command=()
  mapfile -t command < <(jq -r '.[]?' <<<"$command_json")
  (( ${#command[@]} > 0 )) || {
    jq -cn --arg error "command is required" '{ok:false,error:$error}'
    return 1
  }
  output="$("$(docker_bin)" exec "$cname" "${command[@]}" 2>&1)"
  result=$?
  jq -cn --arg id "$id" --argjson exit_code "$result" --arg output "$output" \
    '{ok:true,id:$id,exit_code:$exit_code,output:$output}'
}

docker_session_snapshot() {
  local id="$1" record cname image tar response snapshot
  record="$(docker_local_session_get "$id")" || {
    jq -cn --arg error "unknown local session" '{ok:false,error:$error}'
    return 1
  }
  cname="$(jq -r '.container' <<<"$record")"
  image="${BEAUT_SNAPSHOT_IMAGE_PREFIX}${id}:$(beaut_now)"
  if ! "$(docker_bin)" commit "$cname" "$image" >/dev/null 2>&1; then
    jq -cn --arg error "docker commit failed" '{ok:false,error:$error}'
    return 1
  fi
  tar="$(mktemp "${TMPDIR:-/tmp}/beaut-snapshot.XXXXXX")" || return 1
  if ! "$(docker_bin)" save -o "$tar" "$image" >/dev/null 2>&1; then
    rm -f -- "$tar"
    jq -cn --arg error "docker save failed" '{ok:false,error:$error}'
    return 1
  fi
  local encoded_name
  encoded_name="$(beaut_url_encode "${BEAUT_SESSION_ROUTE_PREFIX}${id}")"
  if ! response="$(curl -fsS --connect-timeout 3 --max-time "${BEAUT_REPLICA_TIMEOUT:-30}" \
      -X PUT "${BEAUT_HUB_URL}/packages?name=${encoded_name}&kind=${BEAUT_PACKAGE_KIND_SESSION_IMAGE}&copies=${BEAUT_MIN_COPIES}" \
      -H 'Content-Type: application/octet-stream' \
      --data-binary "@$tar" 2>/dev/null)"; then
    rm -f -- "$tar"
    jq -cn --arg error "snapshot upload failed" '{ok:false,error:$error}'
    return 1
  fi
  rm -f -- "$tar"
  snapshot="$(jq -r '.manifest.id // empty' <<<"$response")"
  [[ -n "$snapshot" ]] || {
    jq -cn --arg error "hub did not return a snapshot id" '{ok:false,error:$error}'
    return 1
  }
  record="$(jq -c --arg ts "$(beaut_iso)" --arg snapshot "$snapshot" --arg image "$image" \
    '.snapshot=$snapshot | .snapshot_image=$image | .updated_at=$ts' <<<"$record")"
  docker_local_session_write "$id" "$record"
  jq -cn --arg id "$id" --arg snapshot "$snapshot" --arg image "$image" \
    '{ok:true,id:$id,snapshot:$snapshot,image:$image}'
}

docker_session_restore() {
  local id="$1" snapshot="$2" requested_image="${3:-}" container_port="${4:-0}"
  local protocol="${5:-http}" command_json="${6:-[]}" name="${7:-$1}"
  local tar loaded image record spec cname
  [[ -n "$snapshot" ]] || {
    jq -cn --arg error "missing snapshot" '{ok:false,error:$error}'
    return 1
  }
  tar="$(mktemp "${TMPDIR:-/tmp}/beaut-restore.XXXXXX")" || return 1
  if ! curl -fsS --connect-timeout 3 --max-time "${BEAUT_REPLICA_TIMEOUT:-30}" \
       "${BEAUT_HUB_URL}/packages/${snapshot}/download" -o "$tar" 2>/dev/null; then
    rm -f -- "$tar"
    jq -cn --arg error "snapshot download failed" '{ok:false,error:$error}'
    return 1
  fi
  if ! loaded="$("$(docker_bin)" load -i "$tar" 2>&1)"; then
    rm -f -- "$tar"
    jq -cn --arg error "$loaded" '{ok:false,error:$error}'
    return 1
  fi
  rm -f -- "$tar"
  image="$requested_image"
  if [[ -z "$image" ]]; then
    image="$(sed -n 's/^Loaded image: //p' <<<"$loaded" | tail -1)"
  fi
  [[ -n "$image" ]] || {
    jq -cn --arg error "docker load did not report an image" '{ok:false,error:$error}'
    return 1
  }

  record="$(docker_local_session_get "$id" 2>/dev/null || true)"
  if [[ -n "$record" ]]; then
    cname="$(jq -r '.container' <<<"$record")"
    "$(docker_bin)" rm -f "$cname" >/dev/null 2>&1 || true
    spec="$(mktemp "${TMPDIR:-/tmp}/beaut-spec.XXXXXX")" || return 1
    docker_session_spec "$(jq -c --arg image "$image" '.image=$image' <<<"$record")" "$spec"
  else
    spec="$(mktemp "${TMPDIR:-/tmp}/beaut-spec.XXXXXX")" || return 1
    jq -cn --arg id "$id" --arg name "$name" --arg image "$image" \
      --argjson container_port "$container_port" --arg protocol "$protocol" \
      --argjson command "$command_json" \
      '{id:$id,name:$name,image:$image,container_port:$container_port,
        protocol:$protocol,command:$command}' > "$spec"
  fi
  docker_session_run_file "$spec" 1
  local result=$?
  rm -f -- "$spec"
  [[ "$result" == "0" ]] || return "$result"
  record="$(docker_local_session_get "$id")"
  record="$(jq -c --arg snapshot "$snapshot" --arg image "$image" --arg ts "$(beaut_iso)" \
    '.snapshot=$snapshot | .snapshot_image=$image | .updated_at=$ts' <<<"$record")"
  docker_local_session_write "$id" "$record"
}

docker_restore_all() {
  local file id status record spec
  shopt -s nullglob
  for file in "$BEAUT_STATE_DIR"/sessions/*.json; do
    [[ -f "$file" ]] || continue
    id="$(jq -r '.id // ""' "$file" 2>/dev/null || true)"
    [[ -n "$id" ]] || continue
    status="$(jq -r '.status // ""' "$file")"
    [[ "$status" == "running" ]] || continue
    record="$(cat -- "$file")"
    if "$(docker_bin)" inspect "$(docker_container_name "$id")" >/dev/null 2>&1; then
      docker_session_start "$id" >/dev/null 2>&1 || true
    else
      spec="$(mktemp "${TMPDIR:-/tmp}/beaut-spec.XXXXXX")" || continue
      docker_session_spec "$record" "$spec"
      docker_session_run_file "$spec" >/dev/null 2>&1 || true
      rm -f -- "$spec"
    fi
  done
  shopt -u nullglob
}

docker_session_list_local() {
  local file
  local -a files=()
  shopt -s nullglob
  files=("$BEAUT_STATE_DIR"/sessions/*.json)
  shopt -u nullglob
  if (( ${#files[@]} == 0 )); then
    printf '[]\n'
  else
    jq -s 'sort_by(.created_at) | reverse' "${files[@]}"
  fi
}
