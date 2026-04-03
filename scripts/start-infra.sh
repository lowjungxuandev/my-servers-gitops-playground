#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NODES=(cluster-node application-node infrastructure-node)
KUBERNETES_MINOR_VERSION="v1.35"
PAUSE_IMAGE="registry.k8s.io/pause:3.10.1"

install_prereqs() {
  local node="$1"
  docker exec "$node" bash -lc '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl gpg iproute2 iptables socat conntrack containerd kmod

    mkdir -p /etc/apt/keyrings
    curl -fsSL https://pkgs.k8s.io/core:/stable:/'"$KUBERNETES_MINOR_VERSION"'/deb/Release.key | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/'"$KUBERNETES_MINOR_VERSION"'/deb/ /" > /etc/apt/sources.list.d/kubernetes.list

    apt-get update
    apt-get install -y kubeadm kubelet kubectl cri-tools
    apt-mark hold kubeadm kubelet kubectl cri-tools

    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
    # Docker Desktop backs these containers with overlayfs already. Use the
    # native snapshotter to avoid nested overlayfs mount failures.
    sed -Ei "s#^([[:space:]]*snapshotter = )\"overlayfs\"#\1\"native\"#" /etc/containerd/config.toml
    sed -Ei "s#^([[:space:]]*sandbox_image = ).*#\1\"'"$PAUSE_IMAGE"'\"#" /etc/containerd/config.toml
    sed -Ei "s#^([[:space:]]*SystemdCgroup = ).*#\1false#" /etc/containerd/config.toml

    cat >/etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

    swapoff -a || true
    rm -f /var/lib/swap /swap.img || true
    modprobe overlay || true
    modprobe br_netfilter || true
    sysctl -w net.ipv4.ip_forward=1 || true
    sysctl -w net.bridge.bridge-nf-call-iptables=1 || true
    sysctl -w net.bridge.bridge-nf-call-ip6tables=1 || true

    mkdir -p /var/lib/kubelet /var/log /var/run /etc/default
    NODE_IP="$(hostname -i | cut -d" " -f1)"
    cat >/etc/default/kubelet <<EOF
KUBELET_EXTRA_ARGS="--node-ip=$NODE_IP"
EOF

    cat >/usr/local/bin/kubelet-launcher.sh <<'\''EOF'\''
#!/usr/bin/env bash
set -euo pipefail

KUBELET_KUBECONFIG_ARGS="--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
KUBELET_CONFIG_ARGS="--config=/var/lib/kubelet/config.yaml"
KUBELET_KUBEADM_ARGS=""
KUBELET_EXTRA_ARGS=""

if [ -f /var/lib/kubelet/kubeadm-flags.env ]; then
  . /var/lib/kubelet/kubeadm-flags.env
fi

if [ -f /etc/default/kubelet ]; then
  . /etc/default/kubelet
fi

exec /usr/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
EOF
    chmod +x /usr/local/bin/kubelet-launcher.sh

    cat >/usr/local/bin/kubelet-supervisor.sh <<'\''EOF'\''
#!/usr/bin/env bash
set -euo pipefail

while true; do
  /usr/local/bin/kubelet-launcher.sh >>/var/log/kubelet.log 2>&1 || true
  sleep 2
done
EOF
    chmod +x /usr/local/bin/kubelet-supervisor.sh

    pkill containerd || true
    nohup containerd >/var/log/containerd.log 2>&1 &

    timeout 30 sh -c "until crictl info >/dev/null 2>&1; do sleep 1; done"

    if [ -f /var/run/kubelet-supervisor.pid ]; then
      kill "$(cat /var/run/kubelet-supervisor.pid)" 2>/dev/null || true
      rm -f /var/run/kubelet-supervisor.pid
    fi
    pkill kubelet || true
    nohup /usr/local/bin/kubelet-supervisor.sh >/var/log/kubelet-supervisor.log 2>&1 </dev/null &
    echo $! >/var/run/kubelet-supervisor.pid
  '
}

cd "$PROJECT_DIR"

if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is not running."
  echo "Start Docker Desktop, then run this script again."
  exit 1
fi

docker compose up -d

for node in "${NODES[@]}"; do
  install_prereqs "$node"
done

echo
echo "Servers are running and node prerequisites are installed."
echo "Open a shell with one of:"
echo "docker exec -it cluster-node bash"
echo "docker exec -it application-node bash"
echo "docker exec -it infrastructure-node bash"
