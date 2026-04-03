#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

"$PROJECT_DIR/scripts/recreate-nodes.sh"
"$PROJECT_DIR/scripts/install-kubernetes-cluster.sh"
"$PROJECT_DIR/scripts/bootstrap-argocd.sh"

echo
echo "Lab bootstrap completed."
echo "Kubeconfig: $PROJECT_DIR/kubeconfig.yaml"
echo "Demo app: http://localhost:8080"
echo "Grafana: http://localhost:3000"
echo "Prometheus: http://localhost:9090"
echo "Argo CD: http://localhost:8081"
