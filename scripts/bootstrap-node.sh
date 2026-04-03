#!/usr/bin/env bash

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

KUBERNETES_PACKAGE_CHANNEL="${KUBERNETES_PACKAGE_CHANNEL:-v1.35}"
COREDNS_IMAGE="${COREDNS_IMAGE:-registry.k8s.io/coredns/coredns:v1.14.2}"
FLANNEL_MANIFEST_URL="${FLANNEL_MANIFEST_URL:-https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml}"

install_base_packages() {
  apt-get update
  rm -f /etc/containerd/config.toml
  dpkg --force-confnew --configure -a || true
  apt-get install -y ca-certificates conntrack curl gpg iproute2 iptables kmod socat
}

configure_apt_repositories() {
  mkdir -p /etc/apt/keyrings

  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  . /etc/os-release
  cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable
EOF

  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_PACKAGE_CHANNEL}/deb/Release.key" \
    | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  cat >/etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_PACKAGE_CHANNEL}/deb/ /
EOF
}

install_kubernetes_packages() {
  apt-get update
  apt-get remove -y containerd runc || true
  rm -f /etc/containerd/config.toml
  apt-get install -y -o Dpkg::Options::="--force-confnew" containerd.io kubeadm kubelet kubectl cri-tools
  apt-mark hold kubeadm kubelet kubectl cri-tools
}

configure_containerd() {
  local pause_image

  pause_image="$(cat "$PAUSE_IMAGE_FILE")"
  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml

  sed -Ei "0,/^[[:space:]]*snapshotter = 'overlayfs'$/s//    snapshotter = 'native'/" /etc/containerd/config.toml
  sed -Ei "s#^([[:space:]]*sandbox = ).*#\1'${pause_image}'#" /etc/containerd/config.toml
  sed -Ei "s#^([[:space:]]*SystemdCgroup = ).*#\1false#" /etc/containerd/config.toml

  if ! grep -Eq "^[[:space:]]*snapshotter = 'native'$" /etc/containerd/config.toml; then
    echo "containerd snapshotter was not updated to native" >&2
    grep -n "snapshotter" /etc/containerd/config.toml >&2 || true
    exit 1
  fi

  cat >/etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF
}

configure_node_runtime() {
  local node_ip

  swapoff -a || true
  rm -f /var/lib/swap /swap.img || true
  modprobe overlay || true
  modprobe br_netfilter || true
  sysctl -w net.ipv4.ip_forward=1 || true
  sysctl -w net.bridge.bridge-nf-call-iptables=1 || true
  sysctl -w net.bridge.bridge-nf-call-ip6tables=1 || true

  mkdir -p /var/lib/kubelet /var/log /var/run /etc/default
  node_ip="$(hostname -i | cut -d' ' -f1)"

  cat >/etc/kubernetes-resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
options ndots:5
EOF

  cat >/etc/default/kubelet <<EOF
KUBELET_EXTRA_ARGS="--node-ip=${node_ip}"
EOF
}

install_kubelet_supervisor() {
  cat >/usr/local/bin/kubelet-launcher.sh <<'EOF'
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

  cat >/usr/local/bin/kubelet-supervisor.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

while true; do
  /usr/local/bin/kubelet-launcher.sh >>/var/log/kubelet.log 2>&1 || true
  sleep 2
done
EOF
  chmod +x /usr/local/bin/kubelet-supervisor.sh
}

start_containerd() {
  pkill containerd || true
  nohup containerd >/var/log/containerd.log 2>&1 &
  timeout 30 sh -c "until crictl info >/dev/null 2>&1; do sleep 1; done"
}

ctr_platform() {
  case "$(dpkg --print-architecture)" in
    amd64) echo "linux/amd64" ;;
    arm64) echo "linux/arm64" ;;
    armhf) echo "linux/arm/v7" ;;
    *) echo "linux/$(dpkg --print-architecture)" ;;
  esac
}

prepull_cluster_images() {
  local pause_image
  local platform
  local kubernetes_version

  pause_image="$(cat "$PAUSE_IMAGE_FILE")"
  platform="$(ctr_platform)"
  kubernetes_version="$(kubeadm version -o short)"

  {
    echo "$pause_image"
    kubeadm config images list --kubernetes-version "$kubernetes_version"
    echo "$COREDNS_IMAGE"
    curl -fsSL "$FLANNEL_MANIFEST_URL" | awk '/image:[[:space:]]/ {print $2}'
  } | awk '!seen[$0]++' | while read -r image; do
    [ -n "$image" ] || continue
    ctr -n k8s.io images pull --platform "$platform" --local "$image"
  done >/var/log/bootstrap-image-prepull.log 2>&1 || {
    cat /var/log/bootstrap-image-prepull.log >&2 || true
    exit 1
  }
}

restart_kubelet_supervisor() {
  if [ -f /var/run/kubelet-supervisor.pid ]; then
    kill "$(cat /var/run/kubelet-supervisor.pid)" 2>/dev/null || true
    rm -f /var/run/kubelet-supervisor.pid
  fi

  pkill kubelet || true
  nohup /usr/local/bin/kubelet-supervisor.sh >/var/log/kubelet-supervisor.log 2>&1 </dev/null &
  echo $! >/var/run/kubelet-supervisor.pid
}

main() {
  install_base_packages
  configure_apt_repositories
  install_kubernetes_packages
  configure_containerd
  configure_node_runtime
  install_kubelet_supervisor
  start_containerd
  prepull_cluster_images
  restart_kubelet_supervisor
}

main "$@"
