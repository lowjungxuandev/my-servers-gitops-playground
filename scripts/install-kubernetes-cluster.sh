#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

install_prereqs() {
  local node="$1"
  docker exec "$node" bash -lc '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl gpg iproute2 iptables socat conntrack containerd

    mkdir -p /etc/apt/keyrings
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" > /etc/apt/sources.list.d/kubernetes.list

    apt-get update
    apt-get install -y kubeadm kubelet kubectl
    apt-mark hold kubeadm kubelet kubectl

    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
    sed -i "s/SystemdCgroup = true/SystemdCgroup = false/" /etc/containerd/config.toml

    swapoff -a || true
    modprobe overlay || true
    modprobe br_netfilter || true
    sysctl -w net.ipv4.ip_forward=1 || true
    sysctl -w net.bridge.bridge-nf-call-iptables=1 || true
    sysctl -w net.bridge.bridge-nf-call-ip6tables=1 || true

    pkill containerd || true
    nohup containerd >/var/log/containerd.log 2>&1 &
  '
}

for node in ubuntu-server-1 ubuntu-server-2 ubuntu-server-3; do
  install_prereqs "$node"
done

docker exec ubuntu-server-1 bash -lc '
  pkill kubelet || true
  nohup kubelet \
    --container-runtime-endpoint=unix:///run/containerd/containerd.sock \
    --fail-swap-on=false \
    --hostname-override=ubuntu-server-1 \
    >/var/log/kubelet.log 2>&1 &
'

CONTROL_PLANE_IP="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ubuntu-server-1)"

docker exec ubuntu-server-1 bash -lc "
  kubeadm init \
    --apiserver-advertise-address=$CONTROL_PLANE_IP \
    --apiserver-cert-extra-sans=127.0.0.1,ubuntu-server-1 \
    --pod-network-cidr=10.244.0.0/16 \
    --ignore-preflight-errors=NumCPU,Mem,Swap,SystemVerification
"

docker exec ubuntu-server-1 bash -lc '
  mkdir -p /root/.kube
  cp /etc/kubernetes/admin.conf /root/.kube/config
  kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
'

JOIN_COMMAND="$(docker exec ubuntu-server-1 bash -lc 'kubeadm token create --print-join-command' | tr -d '\r')"

for node in ubuntu-server-2 ubuntu-server-3; do
  docker exec "$node" bash -lc "
    pkill kubelet || true
    nohup kubelet \
      --container-runtime-endpoint=unix:///run/containerd/containerd.sock \
      --fail-swap-on=false \
      --hostname-override=$node \
      >/var/log/kubelet.log 2>&1 &
    $JOIN_COMMAND --ignore-preflight-errors=NumCPU,Mem,Swap,SystemVerification
  "
done

docker exec ubuntu-server-1 bash -lc '
  kubectl label node ubuntu-server-2 workload=app --overwrite
  kubectl label node ubuntu-server-3 workload=monitoring --overwrite
  kubectl wait --for=condition=Ready node/ubuntu-server-1 --timeout=300s
  kubectl wait --for=condition=Ready node/ubuntu-server-2 --timeout=300s
  kubectl wait --for=condition=Ready node/ubuntu-server-3 --timeout=300s
'

docker exec ubuntu-server-1 bash -lc 'cat /etc/kubernetes/admin.conf' \
  | sed "s#https://$CONTROL_PLANE_IP:6443#https://127.0.0.1:6443#g" \
  > "$PROJECT_DIR/kubeconfig.yaml"

echo "Upstream Kubernetes cluster installed with kubeadm."
