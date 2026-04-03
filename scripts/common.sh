#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CONTROL_PLANE_NODE="${CONTROL_PLANE_NODE:-cluster-node}"
APPLICATION_NODE="${APPLICATION_NODE:-application-node}"
INFRASTRUCTURE_NODE="${INFRASTRUCTURE_NODE:-infrastructure-node}"
WORKER_NODES=("$APPLICATION_NODE" "$INFRASTRUCTURE_NODE")
ALL_NODES=("$CONTROL_PLANE_NODE" "${WORKER_NODES[@]}")

KUBERNETES_PACKAGE_CHANNEL="${KUBERNETES_PACKAGE_CHANNEL:-v1.35}"
KUBERNETES_RELEASE_CHANNEL="${KUBERNETES_RELEASE_CHANNEL:-stable-${KUBERNETES_PACKAGE_CHANNEL#v}}"
PAUSE_IMAGE="${PAUSE_IMAGE:-registry.k8s.io/pause:3.10.1}"
COREDNS_IMAGE="${COREDNS_IMAGE:-registry.k8s.io/coredns/coredns:v1.14.2}"
FLANNEL_MANIFEST_URL="${FLANNEL_MANIFEST_URL:-https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml}"

NODE_BOOTSTRAP_SCRIPT="$SCRIPT_DIR/bootstrap-node.sh"
JOIN_COMMAND_FILE="$PROJECT_DIR/join-command.txt"
LOCAL_KUBECONFIG_FILE="$PROJECT_DIR/kubeconfig.yaml"

ensure_docker_running() {
  if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is not running."
    echo "Start Docker Desktop, then run this script again."
    exit 1
  fi
}

node_ip() {
  docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"
}

install_node_prereqs() {
  local node="$1"
  local remote_script="/root/bootstrap-node.sh"
  local remote_pause_file="/root/pause_image"

  docker cp "$NODE_BOOTSTRAP_SCRIPT" "$node:$remote_script"
  docker exec "$node" chmod +x "$remote_script"
  docker exec "$node" sh -c "printf '%s\n' '$PAUSE_IMAGE' > '$remote_pause_file'"
  docker exec \
    -e KUBERNETES_PACKAGE_CHANNEL="$KUBERNETES_PACKAGE_CHANNEL" \
    -e PAUSE_IMAGE_FILE="$remote_pause_file" \
    -e COREDNS_IMAGE="$COREDNS_IMAGE" \
    -e FLANNEL_MANIFEST_URL="$FLANNEL_MANIFEST_URL" \
    "$node" \
    bash "$remote_script"
}

install_all_nodes() {
  local failures=0
  local pids=()
  local nodes=()
  local node
  local i

  for node in "${ALL_NODES[@]}"; do
    install_node_prereqs "$node" &
    pids+=($!)
    nodes+=("$node")
  done

  for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then
      echo "Node setup failed: ${nodes[$i]}" >&2
      failures=1
    fi
  done

  return "$failures"
}

reset_control_plane_node() {
  local node="$1"

  docker exec -i "$node" bash -s <<'EOF'
set -euo pipefail
pkill kubelet || true
kubeadm reset -f || true
rm -rf /etc/cni/net.d/* /var/lib/cni/* /var/lib/etcd/*
rm -f /etc/kubernetes/*.conf
rm -f /var/lib/kubelet/config.yaml /var/lib/kubelet/instance-config.yaml /var/lib/kubelet/kubeadm-flags.env
EOF
}

reset_worker_node() {
  local node="$1"

  docker exec -i "$node" bash -s <<'EOF'
set -euo pipefail
pkill kubelet || true
kubeadm reset -f || true
rm -rf /etc/cni/net.d/* /var/lib/cni/*
rm -f /etc/kubernetes/*.conf
rm -f /var/lib/kubelet/config.yaml /var/lib/kubelet/instance-config.yaml /var/lib/kubelet/kubeadm-flags.env
EOF
}

wait_for_ready_nodes() {
  docker exec -i "$CONTROL_PLANE_NODE" bash -s -- "${ALL_NODES[@]}" <<'EOF'
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf

for node in "$@"; do
  kubectl wait --for=condition=Ready "node/$node" --timeout=300s
done
EOF
}

print_node_shells() {
  printf 'docker exec -it %s bash\n' "${ALL_NODES[@]}"
}
