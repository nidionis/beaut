#!/usr/bin/env bash
# store.sh - content-addressed package store with chunk-level deduplication
# and at-least-N replication across configured workers.
#
# Package id: sha256:<hex of the complete file>
# Chunk id:   sha256:<hex of the chunk>
# Layout:
#   $BEAUT_STORE_DIR/objects/<first2>/<hex>
#   $BEAUT_STORE_DIR/packages/<hex>.json
#   $BEAUT_STORE_DIR/tmp/

store_init() {
  mkdir -p -- \
    "$BEAUT_STORE_DIR/objects" \
    "$BEAUT_STORE_DIR/packages" \
    "$BEAUT_STORE_DIR/tmp"
  chmod 700 "$BEAUT_STORE_DIR" 2>/dev/null || true
}

store_local_name() {
  if [[ "${BEAUT_ROLE:-hub}" == "worker" ]]; then
    printf '%s' "${BEAUT_WORKER_NAME}"
  else
    printf '%s' "${BEAUT_NODE_NAME:-${BEAUT_HUB_NAME}}"
  fi
}

store_package_kind_valid() {
  local wanted="${1:-}" kind
  for kind in "${BEAUT_PACKAGE_KINDS[@]}"; do
    [[ "$kind" == "$wanted" ]] && return 0
  done
  return 1
}

store_id_hex() {
  local id="${1:-}"
  id="${id#sha256:}"
  printf '%s' "$id"
}

store_object_path() {
  local hex
  hex="$(store_id_hex "$1")"
  [[ "$hex" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s/objects/%s/%s' "$BEAUT_STORE_DIR" "${hex:0:2}" "$hex"
}

store_manifest_path() {
  local hex
  hex="$(store_id_hex "$1")"
  [[ "$hex" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s/packages/%s.json' "$BEAUT_STORE_DIR" "$hex"
}

store_hash_file() {
  sha256sum "$1" | awk '{print $1}'
}

store_hash_string() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

store_manifest() {
  local id="$1" path
  path="$(store_manifest_path "$id")" || return 1
  [[ -f "$path" ]] || return 1
  cat -- "$path"
}

store_manifest_exists() {
  local path
  path="$(store_manifest_path "$1")" 2>/dev/null || return 1
  [[ -f "$path" ]]
}

store_write_manifest() {
  local id="$1" manifest="$2" path
  path="$(store_manifest_path "$id")" || return 1
  beaut_atomic_write "$path" "$manifest"
}

store_update_manifest() {
  local id="$1" filter="$2"; shift 2
  local path manifest
  path="$(store_manifest_path "$id")" || return 1
  beaut_state_lock 5 || return 1
  if [[ ! -f "$path" ]]; then
    beaut_state_unlock
    return 1
  fi
  manifest="$(jq -c "$@" "$filter" "$path")" || {
    beaut_state_unlock
    return 1
  }
  beaut_atomic_write "$path" "$manifest" || {
    beaut_state_unlock
    return 1
  }
  beaut_state_unlock
}

store_add_copy() {
  local id="$1" node="$2"
  [[ -n "$node" ]] || return 0
  store_update_manifest "$id" \
    '.copies = ((.copies // []) + [$node] | unique) | .degraded = ((.copies | length) < (.required_copies // $required))' \
    --arg node "$node" --argjson required "$BEAUT_MIN_COPIES"
}

store_add_file() {
  local file="$1" name="${2:-$(basename "$1")}"
  local kind="${3:-$BEAUT_PACKAGE_KIND_DEFAULT}"
  local required="${4:-$BEAUT_MIN_COPIES}" tmp result
  [[ -f "$file" ]] || {
    beaut_warn "not a regular file: $file"
    return 1
  }
  store_init
  tmp="$(mktemp -d "${BEAUT_STORE_DIR}/tmp/add.XXXXXX")" || return 1
  _store_add_file_work "$file" "$name" "$kind" "$required" "$tmp"
  result=$?
  rm -rf -- "$tmp"
  return "$result"
}

_store_add_file_work() {
  local file="$1" name="$2" kind="$3" required="$4" tmp="$5"
  local size hash hex manifest id chunk chunk_hash object
  split -b "${BEAUT_CHUNK_SIZE:-1048576}" -d -a 6 -- "$file" "$tmp/chunk." || return 1
  : > "$tmp/chunks"
  if compgen -G "$tmp/chunk.*" >/dev/null; then
    for chunk in "$tmp"/chunk.*; do
      chunk_hash="$(store_hash_file "$chunk")"
      object="$(store_object_path "sha256:$chunk_hash")" || return 1
      if [[ ! -f "$object" ]]; then
        mkdir -p -- "$(dirname "$object")"
        mv -f -- "$chunk" "$object"
        chmod 600 "$object" 2>/dev/null || true
      else
        rm -f -- "$chunk"
      fi
      printf 'sha256:%s\n' "$chunk_hash" >> "$tmp/chunks"
    done
  fi

  size="$(beaut_file_size "$file")"
  hash="$(store_hash_file "$file")"
  hex="$hash"
  id="sha256:$hex"
  manifest="$(jq -cn \
    --arg schema "$BEAUT_PACKAGE_SCHEMA" \
    --arg id "$id" \
    --arg name "$name" \
    --arg kind "$kind" \
    --argjson size "$size" \
    --argjson chunk_size "${BEAUT_CHUNK_SIZE:-1048576}" \
    --argjson copies '[]' \
    --argjson required "$required" \
    --arg created_at "$(beaut_iso)" \
    --arg local "$(store_local_name)" \
    --rawfile chunks "$tmp/chunks" \
    '{schema:$schema,id:$id,name:$name,kind:$kind,size:$size,
      chunk_size:$chunk_size,
      chunks:($chunks | split("\n") | map(select(length>0))),
      copies:([$local] + $copies | unique),
      required_copies:$required,
      created_at:$created_at,
      degraded: (($copies | length) + 1 < $required)}')" || return 1
  store_write_manifest "$id" "$manifest" || return 1
  printf '%s\n' "$id"
}

store_list() {
  local file
  local -a files=()
  shopt -s nullglob
  files=("$BEAUT_STORE_DIR"/packages/*.json)
  shopt -u nullglob
  if (( ${#files[@]} == 0 )); then
    printf '[]\n'
    return 0
  fi
  jq -s 'sort_by(.created_at) | reverse' "${files[@]}"
}

store_verify_manifest_dir() {
  local manifest="$1" root="$2" full="${3:-0}"
  local id chunk hex path actual tmp
  id="$(jq -r '.id' "$manifest")"
  [[ "$id" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  while IFS= read -r chunk; do
    [[ -n "$chunk" ]] || continue
    hex="$(store_id_hex "$chunk")"
    [[ "$hex" =~ ^[0-9a-f]{64}$ ]] || return 1
    path="$root/objects/${hex:0:2}/$hex"
    [[ -f "$path" ]] || return 1
    actual="$(store_hash_file "$path")"
    [[ "$actual" == "$hex" ]] || return 1
  done < <(jq -r '.chunks[]?' "$manifest")

  if [[ "$full" == "1" ]]; then
    tmp="$(mktemp "${BEAUT_STORE_DIR}/tmp/verify.XXXXXX")" || return 1
    local chunk_path
    : > "$tmp"
    while IFS= read -r chunk; do
      [[ -n "$chunk" ]] || continue
      hex="$(store_id_hex "$chunk")"
      chunk_path="$root/objects/${hex:0:2}/$hex"
      cat -- "$chunk_path" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
    done < <(jq -r '.chunks[]?' "$manifest")
    actual="sha256:$(store_hash_file "$tmp")"
    rm -f -- "$tmp"
    [[ "$actual" == "$id" ]] || return 1
  fi
  return 0
}

# True when the manifest and every chunk object are present locally.
# Hashes are checked by verify/receive paths; this is the cheap presence test
# used before deciding whether a peer fetch is useful.
store_manifest_complete() {
  local id="$1" manifest chunk hex
  manifest="$(store_manifest "$id")" || return 1
  while IFS= read -r chunk; do
    [[ -n "$chunk" ]] || continue
    hex="$(store_id_hex "$chunk")"
    [[ -f "$BEAUT_STORE_DIR/objects/${hex:0:2}/$hex" ]] || return 1
  done < <(jq -r '.chunks[]?' <<<"$manifest")
  return 0
}

store_verify() {
  local id="$1" full="${2:-0}" manifest tmp
  manifest="$(store_manifest "$id")" || {
    printf 'missing %s\n' "$id"
    return 1
  }
  tmp="$(mktemp "${BEAUT_STORE_DIR}/tmp/manifest.XXXXXX")" || return 1
  printf '%s\n' "$manifest" > "$tmp"
  store_verify_manifest_dir "$tmp" "$BEAUT_STORE_DIR" "$full"
  local result=$?
  rm -f -- "$tmp"
  return "$result"
}

store_get_file() {
  local id="$1" output="$2" manifest chunk hex tmp
  manifest="$(store_manifest "$id")" || return 1
  tmp="${output}.tmp.$$"
  : > "$tmp" || return 1
  while IFS= read -r chunk; do
    [[ -n "$chunk" ]] || continue
    hex="$(store_id_hex "$chunk")"
    cat -- "$BEAUT_STORE_DIR/objects/${hex:0:2}/$hex" >> "$tmp" || {
      rm -f -- "$tmp"
      return 1
    }
  done < <(jq -r '.chunks[]?' <<<"$manifest")
  if [[ "sha256:$(store_hash_file "$tmp")" != "$id" ]]; then
    rm -f -- "$tmp"
    beaut_warn "package integrity failure: $id"
    return 1
  fi
  mv -f -- "$tmp" "$output"
}

store_bundle() {
  local id="$1" output="$2" manifest stage chunk hex
  manifest="$(store_manifest "$id")" || return 1
  stage="$(mktemp -d "${BEAUT_STORE_DIR}/tmp/bundle.XXXXXX")" || return 1
  mkdir -p -- "$stage/objects" "$stage/packages"
  printf '%s\n' "$manifest" > "$stage/packages/${id#sha256:}.json"
  cp -- "$stage/packages/${id#sha256:}.json" "$stage/manifest.json"
  while IFS= read -r chunk; do
    [[ -n "$chunk" ]] || continue
    hex="$(store_id_hex "$chunk")"
    mkdir -p -- "$stage/objects/${hex:0:2}"
    cp -n -- "$BEAUT_STORE_DIR/objects/${hex:0:2}/$hex" "$stage/objects/${hex:0:2}/$hex" 2>/dev/null || true
  done < <(jq -r '.chunks[]?' <<<"$manifest")
  tar -czf "$output" -C "$stage" . || {
    rm -rf -- "$stage"
    return 1
  }
  rm -rf -- "$stage"
}

store_receive_bundle() {
  local bundle="$1" stage result
  [[ -f "$bundle" ]] || return 1
  stage="$(mktemp -d "${BEAUT_STORE_DIR}/tmp/incoming.XXXXXX")" || return 1
  _store_receive_bundle_work "$bundle" "$stage"
  result=$?
  rm -rf -- "$stage"
  return "$result"
}

_store_receive_bundle_work() {
  local bundle="$1" stage="$2" entry manifest id chunk hex local_name result=0
  local -a entries
  mapfile -t entries < <(tar -tzf "$bundle" 2>/dev/null) || return 1
  (( ${#entries[@]} > 0 )) || return 1
  for entry in "${entries[@]}"; do
    case "$entry" in
      /*|*..*) return 1 ;;
    esac
  done
  tar -xzf "$bundle" -C "$stage" --no-same-owner --no-same-permissions || return 1
  [[ -f "$stage/manifest.json" ]] || return 1
  manifest="$stage/manifest.json"
  id="$(jq -r '.id' "$manifest")"
  [[ "$id" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  store_verify_manifest_dir "$manifest" "$stage" 1 || return 1

  beaut_state_lock 5 || return 1
  while IFS= read -r chunk; do
    [[ -n "$chunk" ]] || continue
    hex="$(store_id_hex "$chunk")"
    mkdir -p -- "$BEAUT_STORE_DIR/objects/${hex:0:2}"
    cp -n -- "$stage/objects/${hex:0:2}/$hex" \
      "$BEAUT_STORE_DIR/objects/${hex:0:2}/$hex" 2>/dev/null || result=1
  done < <(jq -r '.chunks[]?' "$manifest")
  if (( result == 0 )); then
    local_name="$(store_local_name)"
    store_write_manifest "$id" "$(jq -c --arg local "$local_name" \
      --argjson required "$BEAUT_MIN_COPIES" \
      '.copies = (((.copies // []) + [$local]) | unique) | .degraded = ((.copies | length) < (.required_copies // $required))' "$manifest")" \
      || result=1
  fi
  beaut_state_unlock
  (( result == 0 )) || return 1
  printf '%s\n' "$id"
}

store_worker_candidates() {
  local row name host port hub weight
  if declare -F worker_rows >/dev/null 2>&1; then
    worker_rows
    return 0
  fi
  for row in "${BEAUT_WORKERS[@]:-}"; do
    [[ -n "$row" ]] && printf '%s\n' "$row"
  done
}

store_replicate() {
  local id="$1" required manifest copies node_in copies_in
  local -a candidates
  local name host port hub weight bundle response ok
  manifest="$(store_manifest "$id")" || return 1
  required="$(jq -r --argjson fallback "$BEAUT_MIN_COPIES" \
    '.required_copies // $fallback' <<<"$manifest")"
  mapfile -t candidates < <(store_worker_candidates)

  for candidate in "${candidates[@]}"; do
    IFS='|' read -r name host port hub weight <<<"$candidate"
    [[ -n "$name" && -n "$host" && -n "$port" ]] || continue
    [[ "$name" != "$(store_local_name)" ]] || continue
    manifest="$(store_manifest "$id")" || return 1
    copies_in="$(jq -r '.copies // [] | .[]' <<<"$manifest")"
    if grep -Fxq -- "$name" <<<"$copies_in"; then
      continue
    fi
    bundle="$(mktemp "${BEAUT_STORE_DIR}/tmp/out.XXXXXX")" || return 1
    if store_bundle "$id" "$bundle" \
       && response="$(curl -fsS --connect-timeout 3 --max-time "$BEAUT_REPLICA_TIMEOUT" \
            -X PUT "http://${host}:${port}/store/bundle" \
            -H 'Content-Type: application/gzip' \
            --data-binary "@$bundle" 2>/dev/null)" \
       && jq -e '.ok == true' >/dev/null 2>&1 <<<"$response"; then
      store_add_copy "$id" "$name"
      beaut_log "replicated $id -> $name"
    else
      beaut_warn "replication to $name failed for $id"
    fi
    rm -f -- "$bundle"
    manifest="$(store_manifest "$id")" || return 1
    copies_in="$(jq -r '.copies // [] | length' <<<"$manifest")"
    (( copies_in >= required )) && break
  done

  manifest="$(store_manifest "$id")" || return 1
  copies_in="$(jq -r '.copies // [] | length' <<<"$manifest")"
  store_update_manifest "$id" '.degraded = $degraded' \
    --argjson degraded "$([[ "$copies_in" -lt "$required" ]] && echo true || echo false)" \
    >/dev/null 2>&1 || true
  (( copies_in >= required ))
}

store_fetch() {
  local id="$1" row name host port hub weight bundle response
  # A manifest without all of its chunks is still worth repairing from peers.
  if store_manifest_complete "$id"; then
    return 0
  fi
  while IFS='|' read -r name host port hub weight; do
    [[ -n "$name" && -n "$host" && -n "$port" ]] || continue
    bundle="$(mktemp "${BEAUT_STORE_DIR}/tmp/fetch.XXXXXX")" || return 1
    if curl -fsS --connect-timeout 3 --max-time "$BEAUT_REPLICA_TIMEOUT" \
         "http://${host}:${port}/store/packages/${id}/bundle" -o "$bundle" 2>/dev/null \
       && store_receive_bundle "$bundle" >/dev/null 2>&1; then
      rm -f -- "$bundle"
      return 0
    fi
    rm -f -- "$bundle"
  done < <(store_worker_candidates)
  return 1
}

store_scrub() {
  local file id failed=0
  shopt -s nullglob
  for file in "$BEAUT_STORE_DIR"/packages/*.json; do
    id="$(jq -r '.id' "$file" 2>/dev/null || true)"
    [[ -n "$id" ]] || continue
    if store_verify "$id" 1; then
      printf 'ok %s\n' "$id"
    else
      printf 'FAIL %s\n' "$id"
      failed=1
    fi
  done
  shopt -u nullglob
  return "$failed"
}

store_stats() {
  local objects packages bytes
  objects="$(find "$BEAUT_STORE_DIR/objects" -type f 2>/dev/null | wc -l | tr -d ' ')"
  packages="$(find "$BEAUT_STORE_DIR/packages" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')"
  bytes="$(find "$BEAUT_STORE_DIR/objects" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}')"
  jq -cn --argjson objects "$objects" --argjson packages "$packages" --argjson bytes "$bytes" \
    '{objects:$objects,packages:$packages,bytes:$bytes}'
}

# Machine-readable scrub result: {ok,results:[{id,ok}]}.
store_scrub_json() {
  local file id result failed=0
  local -a rows=()
  shopt -s nullglob
  for file in "$BEAUT_STORE_DIR"/packages/*.json; do
    id="$(jq -r '.id' "$file" 2>/dev/null || true)"
    [[ -n "$id" ]] || continue
    result=false
    if store_verify "$id" 1; then result=true; else failed=1; fi
    rows+=("$(jq -cn --arg id "$id" --argjson ok "$result" \
      '{id:$id,ok:$ok}')")
  done
  shopt -u nullglob
  if (( ${#rows[@]} == 0 )); then
    jq -cn --argjson ok "$([[ "$failed" == "0" ]] && echo true || echo false)" \
      '{ok:$ok,results:[]}'
  else
    printf '%s\n' "${rows[@]}" | jq -s \
      --argjson ok "$([[ "$failed" == "0" ]] && echo true || echo false)" \
      '{ok:$ok,results:.}'
  fi
  return "$failed"
}
