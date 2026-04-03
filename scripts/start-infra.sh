#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/node/shared.sh
source "$SCRIPT_DIR/node/shared.sh"

NODE_SETUP_SCRIPTS=(
  "$SCRIPT_DIR/node/cluster-node-setup.sh"
  "$SCRIPT_DIR/node/application-node-setup.sh"
  "$SCRIPT_DIR/node/infrastructure-node-setup.sh"
)

cd "$PROJECT_DIR"

ensure_docker_running

docker compose up -d

status=0
pids=()

for node_script in "${NODE_SETUP_SCRIPTS[@]}"; do
  "$node_script" &
  pids+=($!)
done

for i in "${!pids[@]}"; do
  if ! wait "${pids[$i]}"; then
    echo "Node setup failed: ${NODE_SETUP_SCRIPTS[$i]}" >&2
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  exit "$status"
fi

echo
echo "Servers are running and node prerequisites are installed."
echo "Open a shell with one of:"
echo "docker exec -it cluster-node bash"
echo "docker exec -it application-node bash"
echo "docker exec -it infrastructure-node bash"
