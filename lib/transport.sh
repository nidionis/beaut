# transport.sh - reverse SSH tunnels for workers and the public relay.

run_tunnel() {
  need ssh
  [[ -n "$HUB_SSH" ]] || die "HUB_SSH is empty"
  is_uint "$TUNNEL_PORT" || die "TUNNEL_PORT is empty"
  is_uint "$WORKER_PORT" || die "WORKER_PORT is invalid"

  log "reverse tunnel 127.0.0.1:${TUNNEL_PORT} -> worker:${WORKER_PORT} via ${HUB_SSH}"
  exec ssh -NT \
    -o BatchMode=yes \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -R "127.0.0.1:${TUNNEL_PORT}:127.0.0.1:${WORKER_PORT}" \
    "$HUB_SSH"
}

run_relay() {
  need ssh
  [[ -n "$HUB_RELAY" ]] || die "HUB_RELAY is empty"
  is_uint "$HUB_RELAY_PORT" || die "HUB_RELAY_PORT is invalid"
  is_uint "$PORT" || die "PORT is invalid"

  log "public relay 127.0.0.1:${HUB_RELAY_PORT} -> hub:${PORT} via ${HUB_RELAY}"
  exec ssh -NT \
    -o BatchMode=yes \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -R "127.0.0.1:${HUB_RELAY_PORT}:127.0.0.1:${PORT}" \
    "$HUB_RELAY"
}
