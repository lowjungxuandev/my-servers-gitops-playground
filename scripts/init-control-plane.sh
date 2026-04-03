#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTROL_PLANE_NODE="${1:-cluster-node}"
COREDNS_IMAGE="registry.k8s.io/coredns/coredns:v1.14.2"

reset_control_plane() {
  local node="$1"
  docker exec "$node" bash -lc '
    set -euo pipefail
    pkill kubelet || true

    kubeadm reset -f || true
    rm -rf /etc/cni/net.d/* /var/lib/cni/* /var/lib/etcd/*
    rm -f /etc/kubernetes/*.conf
    rm -f /var/lib/kubelet/config.yaml /var/lib/kubelet/instance-config.yaml /var/lib/kubelet/kubeadm-flags.env
  '
}

reset_control_plane "$CONTROL_PLANE_NODE"

CONTROL_PLANE_IP="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTROL_PLANE_NODE")"

docker exec "$CONTROL_PLANE_NODE" bash -lc "
  cat >/root/kubeadm-init.yaml <<EOF
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
kubernetesVersion: stable-1.35
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
EOF

  kubeadm init \
    --config /root/kubeadm-init.yaml \
    --ignore-preflight-errors=NumCPU,Mem,Swap,SystemVerification,ContainerRuntimeVersion
"

docker exec "$CONTROL_PLANE_NODE" bash -lc '
  timeout 180 sh -c "until curl -sk https://127.0.0.1:6443/healthz >/dev/null; do sleep 2; done"
  mkdir -p /root/.kube
  cp /etc/kubernetes/admin.conf /root/.kube/config
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system get configmap kube-proxy -o yaml \
    | sed "s/maxPerCore: null/maxPerCore: 0/" \
    | sed "s/min: null/min: 0/" \
    | KUBECONFIG=/etc/kubernetes/admin.conf kubectl apply -f -
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system rollout restart daemonset/kube-proxy
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
'

docker exec "$CONTROL_PLANE_NODE" bash -lc "
  export KUBECONFIG=/etc/kubernetes/admin.conf
  kubectl -n kube-system set image deployment/coredns coredns=$COREDNS_IMAGE
  kubectl -n kube-system get configmap coredns -o yaml \
    | sed 's#forward \\. /etc/resolv.conf {#forward . 1.1.1.1 8.8.8.8 {#' \
    | kubectl apply -f -
  kubectl -n kube-system rollout restart deployment/coredns
"

docker exec "$CONTROL_PLANE_NODE" bash -lc 'KUBECONFIG=/etc/kubernetes/admin.conf kubeadm token create --print-join-command' \
  | tr -d '\r' \
  | sed 's#$# --cri-socket unix:///run/containerd/containerd.sock#' \
  > "$PROJECT_DIR/join-command.txt"

docker exec "$CONTROL_PLANE_NODE" bash -lc 'cat /etc/kubernetes/admin.conf' \
  | sed "s#https://$CONTROL_PLANE_IP:6443#https://127.0.0.1:6443#g" \
  > "$PROJECT_DIR/kubeconfig.yaml"

echo "Control plane initialized on $CONTROL_PLANE_NODE"
echo "Join command saved to $PROJECT_DIR/join-command.txt"
