#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

control_kubectl() {
  docker exec ubuntu-server-1 kubectl "$@"
}

control_kubectl create namespace argocd --dry-run=client -o yaml | docker exec -i ubuntu-server-1 kubectl apply -f -
docker exec ubuntu-server-1 sh -lc "kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
control_kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
control_kubectl -n argocd patch svc argocd-server -p '{"spec":{"type":"NodePort","ports":[{"name":"http","port":80,"protocol":"TCP","targetPort":8080,"nodePort":30081},{"name":"https","port":443,"protocol":"TCP","targetPort":8080}]}}'

cat "$PROJECT_DIR/gitops/bootstrap/root-application.yaml" | docker exec -i ubuntu-server-1 kubectl apply -f -

echo "Argo CD bootstrapped."
