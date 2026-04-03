#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"

control_plane_node="${1:-$CONTROL_PLANE_NODE}"
control_plane_ip="$(node_ip "$control_plane_node")"

write_kubeadm_config() {
  docker exec -i \
    -e CONTROL_PLANE_NODE="$control_plane_node" \
    -e CONTROL_PLANE_IP="$control_plane_ip" \
    -e KUBERNETES_RELEASE_CHANNEL="$KUBERNETES_RELEASE_CHANNEL" \
    "$control_plane_node" \
    bash -s <<'EOF'
cat >/root/kubeadm-init.yaml <<EOF_CONFIG
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: $CONTROL_PLANE_IP
  bindPort: 6443
nodeRegistration:
  name: $CONTROL_PLANE_NODE
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: $KUBERNETES_RELEASE_CHANNEL
apiServer:
  certSANs:
    - 127.0.0.1
    - $CONTROL_PLANE_NODE
networking:
  podSubnet: 10.244.0.0/16
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: cgroupfs
failSwapOn: false
resolvConf: /etc/kubernetes-resolv.conf
EOF_CONFIG
EOF
}

initialize_control_plane() {
  docker exec -i "$control_plane_node" bash -s <<'EOF'
set -euo pipefail
kubeadm init \
  --config /root/kubeadm-init.yaml \
  --ignore-preflight-errors=NumCPU,Mem,Swap,SystemVerification,ContainerRuntimeVersion
EOF
}

configure_cluster_addons() {
  docker exec -i \
    -e FLANNEL_MANIFEST_URL="$FLANNEL_MANIFEST_URL" \
    -e COREDNS_IMAGE="$COREDNS_IMAGE" \
    "$control_plane_node" \
    bash -s <<'EOF'
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf

timeout 180 sh -c "until curl -sk https://127.0.0.1:6443/healthz >/dev/null; do sleep 2; done"
  mkdir -p /root/.kube
  cp /etc/kubernetes/admin.conf /root/.kube/config
  kubectl -n kube-system get configmap kube-proxy -o yaml \
    | sed "s/maxPerCore: null/maxPerCore: 0/" \
    | sed "s/min: null/min: 0/" \
    | kubectl apply -f -
  kubectl -n kube-system rollout restart daemonset/kube-proxy
  kubectl apply -f "$FLANNEL_MANIFEST_URL"
  kubectl -n kube-system set image deployment/coredns coredns="$COREDNS_IMAGE"
  kubectl -n kube-system get configmap coredns -o yaml \
    | sed 's#forward \\. /etc/resolv.conf {#forward . 1.1.1.1 8.8.8.8 {#' \
    | kubectl apply -f -
  kubectl -n kube-system rollout restart deployment/coredns
EOF
}

write_cluster_access_files() {
  docker exec -i "$control_plane_node" bash -s <<'EOF' \
    | tr -d '\r' \
    | sed 's#$# --cri-socket unix:///run/containerd/containerd.sock#' \
    > "$JOIN_COMMAND_FILE"
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
kubeadm token create --print-join-command
EOF

  docker exec -i "$control_plane_node" bash -s <<'EOF' \
    | sed "s#https://$control_plane_ip:6443#https://127.0.0.1:6443#g" \
    > "$LOCAL_KUBECONFIG_FILE"
set -euo pipefail
cat /etc/kubernetes/admin.conf
EOF
}

reset_control_plane_node "$control_plane_node"
write_kubeadm_config
initialize_control_plane
configure_cluster_addons
write_cluster_access_files

echo "Control plane initialized on $control_plane_node"
echo "Join command saved to $JOIN_COMMAND_FILE"
