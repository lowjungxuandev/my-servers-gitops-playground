#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"

if [ "$#" -gt 0 ]; then
  WORKERS=("$@")
else
  WORKERS=("${WORKER_NODES[@]}")
fi

if [ ! -f "$JOIN_COMMAND_FILE" ]; then
  echo "Missing $JOIN_COMMAND_FILE. Run scripts/init-control-plane.sh first." >&2
  exit 1
fi

JOIN_COMMAND="$(cat "$JOIN_COMMAND_FILE")"

join_worker() {
  local node="$1"

  reset_worker_node "$node"
  docker exec "$node" bash -lc "$JOIN_COMMAND --ignore-preflight-errors=NumCPU,Mem,Swap,SystemVerification,ContainerRuntimeVersion"
}

label_workers() {
  docker exec -i "$CONTROL_PLANE_NODE" bash -s -- "$APPLICATION_NODE" "$INFRASTRUCTURE_NODE" <<'EOF'
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf

kubectl label node "$1" workload=app --overwrite
kubectl label node "$2" workload=monitoring --overwrite
EOF
}

for node in "${WORKERS[@]}"; do
  join_worker "$node"
done

label_workers
wait_for_ready_nodes

echo "Workers joined: ${WORKERS[*]}"
