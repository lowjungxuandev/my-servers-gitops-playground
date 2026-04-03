#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
JOIN_COMMAND_FILE="$PROJECT_DIR/join-command.txt"
if [ "$#" -gt 0 ]; then
  WORKERS=("$@")
else
  WORKERS=(application-node infrastructure-node)
fi

if [ ! -f "$JOIN_COMMAND_FILE" ]; then
  echo "Missing $JOIN_COMMAND_FILE. Run scripts/init-control-plane.sh first." >&2
  exit 1
fi

JOIN_COMMAND="$(cat "$JOIN_COMMAND_FILE")"

reset_worker() {
  local node="$1"
  docker exec "$node" bash -lc '
    set -euo pipefail
    pkill kubelet || true

    kubeadm reset -f || true
    rm -rf /etc/cni/net.d/* /var/lib/cni/*
    rm -f /etc/kubernetes/*.conf
    rm -f /var/lib/kubelet/config.yaml /var/lib/kubelet/instance-config.yaml /var/lib/kubelet/kubeadm-flags.env
  '
}

for node in "${WORKERS[@]}"; do
  reset_worker "$node"
  docker exec "$node" bash -lc "$JOIN_COMMAND --ignore-preflight-errors=NumCPU,Mem,Swap,SystemVerification,ContainerRuntimeVersion"
done

docker exec cluster-node bash -lc '
  export KUBECONFIG=/etc/kubernetes/admin.conf
  kubectl label node application-node workload=app --overwrite
  kubectl label node infrastructure-node workload=monitoring --overwrite
  kubectl wait --for=condition=Ready node/cluster-node --timeout=300s
  kubectl wait --for=condition=Ready node/application-node --timeout=300s
  kubectl wait --for=condition=Ready node/infrastructure-node --timeout=300s
'

echo "Workers joined: ${WORKERS[*]}"
