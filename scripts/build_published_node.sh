#!/usr/bin/env bash
# build_published_node.sh — render the self-contained /node artifact.
# Usage: build_published_node.sh <server_host> <http_port> [node_source]
#
# The output is a POSIX sh script with the server address baked in, ready for
# `curl .../node | sh` on a machine with no beaut files.
set -euo pipefail

server_host="${1:?usage: build_published_node.sh <server_host> <http_port> [node_source]}"
http_port="${2:?usage: build_published_node.sh <server_host> <http_port> [node_source]}"
node_source="${3:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/node.sh}"

case "$server_host" in
  ''|*[!A-Za-z0-9._:-]*)
    printf 'invalid server host: %s\n' "$server_host" >&2
    exit 2
    ;;
esac
case "$http_port" in
  ''|*[!0-9]*)
    printf 'invalid http port: %s\n' "$http_port" >&2
    exit 2
    ;;
esac
[[ -f "$node_source" ]] || {
  printf 'node source not found: %s\n' "$node_source" >&2
  exit 2
}

printf '#!/bin/sh\n'
printf '# published by deploy.sh: server address baked in, no sourced files.\n'
printf "SERVER_HOST='%s'\n" "$server_host"
printf "HTTP_PORT='%s'\n" "$http_port"
tail -n +2 -- "$node_source"
