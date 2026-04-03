#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR"

docker compose up -d --force-recreate

for name in ubuntu-server-1 ubuntu-server-2 ubuntu-server-3; do
  until docker exec "$name" bash -lc "true" >/dev/null 2>&1; do
    sleep 2
  done
done

echo "Ubuntu nodes are running."
