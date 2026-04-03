#!/usr/bin/env bash

set -euo pipefail

NODE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$NODE_SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
KUBERNETES_MINOR_VERSION="${KUBERNETES_MINOR_VERSION:-v1.35}"
PAUSE_IMAGE="${PAUSE_IMAGE:-registry.k8s.io/pause:3.10.1}"
COREDNS_VERSION="${COREDNS_VERSION:-v1.14.2}"

ensure_docker_running() {
  if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is not running."
    echo "Start Docker Desktop, then run this script again."
    exit 1
  fi
}

install_prereqs() {
  local node="$1"
  local inner_script="$NODE_SCRIPT_DIR/container-setup-inner.sh"
  local remote_inner_script="/root/container-setup-inner.sh"
  local remote_pause_file="/root/pause_image"

  docker cp "$inner_script" "$node:$remote_inner_script"
  docker exec "$node" chmod +x "$remote_inner_script"
  docker exec "$node" sh -c "printf '%s\n' '$PAUSE_IMAGE' >'$remote_pause_file'"
  docker exec \
    -e KUBERNETES_MINOR_VERSION="$KUBERNETES_MINOR_VERSION" \
    -e PAUSE_IMAGE_FILE="$remote_pause_file" \
    -e COREDNS_VERSION="$COREDNS_VERSION" \
    "$node" bash "$remote_inner_script"
}
