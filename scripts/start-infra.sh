#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"

cd "$PROJECT_DIR"

ensure_docker_running

docker compose up -d
install_all_nodes

echo
echo "Servers are running and node prerequisites are installed."
echo "Open a shell with one of:"
print_node_shells
