# worker.sh - answer worker requests and run the worker listener.

handle_worker() {
  local body
  http_accept || return

  case "$HTTP_PATH" in
    /health)
      http_respond "200 OK" "text/plain" $'ok\n'
      ;;
    /info)
      body="$(resources_json)" || {
        http_respond "500 Internal Server Error" "text/plain" $'resource probe failed\n'
        return
      }
      http_respond "200 OK" "application/json" "$body"$'\n'
      ;;
    *)
      http_not_found
      ;;
  esac
}

serve_worker() {
  http_listen worker "$WORKER_PORT" "$WORKER_BIND" beaut-worker-http
}
