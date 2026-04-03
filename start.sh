#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$SCRIPT_DIR"

if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is not running."
  echo "Start Docker Desktop, then run this script again."
  exit 1
fi

docker compose up -d

echo
echo "Servers are starting."
echo "Open a shell with one of:"
echo "docker exec -it ubuntu-server-1 bash"
echo "docker exec -it ubuntu-server-2 bash"
echo "docker exec -it ubuntu-server-3 bash"
