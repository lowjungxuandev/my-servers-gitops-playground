#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_INSTALL_URL="${ARGOCD_INSTALL_URL:-https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml}"
ARGOCD_SERVER_NODEPORT="${ARGOCD_SERVER_NODEPORT:-30081}"
ARGOCD_NODE_SELECTOR_KEY="${ARGOCD_NODE_SELECTOR_KEY:-workload}"
ARGOCD_NODE_SELECTOR_VALUE="${ARGOCD_NODE_SELECTOR_VALUE:-monitoring}"
ARGOCD_IMAGE_PLATFORM="${ARGOCD_IMAGE_PLATFORM:-linux/arm64}"
ARGOCD_BOOTSTRAP_MANIFEST="${ARGOCD_BOOTSTRAP_MANIFEST:-$PROJECT_DIR/gitops/bootstrap/root-application.yaml}"

kubectl_on_control_plane() {
  docker exec -i \
    -e KUBECONFIG=/etc/kubernetes/admin.conf \
    "$CONTROL_PLANE_NODE" \
    kubectl "$@"
}

require_cluster_ready() {
  docker exec -i \
    -e KUBECONFIG=/etc/kubernetes/admin.conf \
    "$CONTROL_PLANE_NODE" \
    kubectl get nodes >/dev/null
}

install_argocd() {
  docker exec -i "$CONTROL_PLANE_NODE" bash -s -- \
    "$ARGOCD_NAMESPACE" \
    "$ARGOCD_INSTALL_URL" <<'EOF'
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf

namespace="$1"
install_url="$2"

kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n "$namespace" --server-side --force-conflicts -f "$install_url"
EOF
}

prepull_argocd_images() {
  local node="$INFRASTRUCTURE_NODE"
  local images=(
    "quay.io/argoproj/argocd:v3.3.6"
    "ghcr.io/dexidp/dex:v2.43.0"
    "public.ecr.aws/docker/library/redis:8.2.3-alpine"
  )
  local image

  for image in "${images[@]}"; do
    docker exec -i "$node" ctr -n k8s.io images pull --platform "$ARGOCD_IMAGE_PLATFORM" "$image"
  done
}

pin_argocd_to_infrastructure() {
  local resource
  local resources=(
    "deployment/argocd-applicationset-controller"
    "deployment/argocd-dex-server"
    "deployment/argocd-notifications-controller"
    "deployment/argocd-redis"
    "deployment/argocd-repo-server"
    "deployment/argocd-server"
    "statefulset/argocd-application-controller"
  )

  for resource in "${resources[@]}"; do
    kubectl_on_control_plane -n "$ARGOCD_NAMESPACE" patch "$resource" --type merge -p \
      "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"$ARGOCD_NODE_SELECTOR_KEY\":\"$ARGOCD_NODE_SELECTOR_VALUE\"}}}}}"
  done
}

set_argocd_pull_policy() {
  kubectl_on_control_plane -n "$ARGOCD_NAMESPACE" patch deployment argocd-applicationset-controller --type json -p \
    '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'
  kubectl_on_control_plane -n "$ARGOCD_NAMESPACE" patch deployment argocd-dex-server --type json -p \
    '[{"op":"replace","path":"/spec/template/spec/initContainers/0/imagePullPolicy","value":"IfNotPresent"},{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'
  kubectl_on_control_plane -n "$ARGOCD_NAMESPACE" patch deployment argocd-notifications-controller --type json -p \
    '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'
  kubectl_on_control_plane -n "$ARGOCD_NAMESPACE" patch deployment argocd-redis --type json -p \
    '[{"op":"replace","path":"/spec/template/spec/initContainers/0/imagePullPolicy","value":"IfNotPresent"},{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'
  kubectl_on_control_plane -n "$ARGOCD_NAMESPACE" patch deployment argocd-repo-server --type json -p \
    '[{"op":"replace","path":"/spec/template/spec/initContainers/0/imagePullPolicy","value":"IfNotPresent"},{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'
  kubectl_on_control_plane -n "$ARGOCD_NAMESPACE" patch deployment argocd-server --type json -p \
    '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'
  kubectl_on_control_plane -n "$ARGOCD_NAMESPACE" patch statefulset argocd-application-controller --type json -p \
    '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'
}

expose_argocd_server() {
  kubectl_on_control_plane -n "$ARGOCD_NAMESPACE" patch service argocd-server --type merge -p \
    "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"name\":\"https\",\"port\":443,\"protocol\":\"TCP\",\"targetPort\":8080,\"nodePort\":$ARGOCD_SERVER_NODEPORT}]}}"
}

restart_argocd_controller() {
  kubectl_on_control_plane -n "$ARGOCD_NAMESPACE" delete pod argocd-application-controller-0 --ignore-not-found=true
}

wait_for_argocd() {
  local resource
  local resources=(
    "deployment/argocd-applicationset-controller"
    "deployment/argocd-dex-server"
    "deployment/argocd-notifications-controller"
    "deployment/argocd-redis"
    "deployment/argocd-repo-server"
    "deployment/argocd-server"
    "statefulset/argocd-application-controller"
  )

  for resource in "${resources[@]}"; do
    kubectl_on_control_plane -n "$ARGOCD_NAMESPACE" rollout status "$resource" --timeout=300s
  done
}

print_admin_password() {
  local password

  password="$(docker exec -i "$CONTROL_PLANE_NODE" bash -lc \
    "export KUBECONFIG=/etc/kubernetes/admin.conf; kubectl -n $ARGOCD_NAMESPACE get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d")"

  echo
  echo "Argo CD is ready."
  echo "URL: https://127.0.0.1:8081"
  echo "Username: admin"
  echo "Password: $password"
}

bootstrap_gitops_if_present() {
  if [ ! -f "$ARGOCD_BOOTSTRAP_MANIFEST" ]; then
    echo
    echo "Skipping GitOps bootstrap."
    echo "Bootstrap manifest not found: $ARGOCD_BOOTSTRAP_MANIFEST"
    return
  fi

  docker cp "$ARGOCD_BOOTSTRAP_MANIFEST" "$CONTROL_PLANE_NODE:/tmp/argocd-bootstrap.yaml"
  docker exec -i "$CONTROL_PLANE_NODE" bash -lc \
    "export KUBECONFIG=/etc/kubernetes/admin.conf; kubectl apply -f /tmp/argocd-bootstrap.yaml"

  echo
  echo "Applied GitOps bootstrap manifest:"
  echo "$ARGOCD_BOOTSTRAP_MANIFEST"
}

require_cluster_ready
prepull_argocd_images
install_argocd
pin_argocd_to_infrastructure
set_argocd_pull_policy
expose_argocd_server
restart_argocd_controller
wait_for_argocd
print_admin_password
bootstrap_gitops_if_present
