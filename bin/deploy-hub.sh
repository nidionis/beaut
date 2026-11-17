#!/usr/bin/env bash
# deploy-hub.sh - install/update the hub. Takes no arguments.
set -uo pipefail

. "$(dirname -- "$0")/../lib/bootstrap.sh"
. "$(dirname -- "$0")/../lib/deploy.sh"
load_config
validate_config
need ssh
need tar
deploy_node hub
