#!/usr/bin/env bash
# deploy-worker.sh - install/update one worker. Takes no arguments.
set -uo pipefail

. "$(dirname -- "$0")/../lib/bootstrap.sh"
. "$(dirname -- "$0")/../lib/deploy.sh"
load_config
validate_config
need ssh
need tar
deploy_node worker
