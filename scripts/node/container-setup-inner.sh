#!/usr/bin/env bash

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
COREDNS_VERSION="${COREDNS_VERSION:-v1.14.2}"

apt-get update
rm -f /etc/containerd/config.toml
dpkg --force-confnew --configure -a || true
apt-get install -y apt-transport-https ca-certificates curl gpg iproute2 iptables socat conntrack kmod

mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list

curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR_VERSION}/deb/Release.key" \
  | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR_VERSION}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list

apt-get update
apt-get remove -y containerd runc || true
rm -f /etc/containerd/config.toml
apt-get install -y -o Dpkg::Options::="--force-confnew" containerd.io kubeadm kubelet kubectl cri-tools
apt-mark hold kubeadm kubelet kubectl cri-tools

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
# Docker Desktop already uses overlayfs underneath these containers. Force the
# native snapshotter here to avoid nested overlayfs mount failures.
PAUSE_IMAGE="$(cat "$PAUSE_IMAGE_FILE")"
sed -Ei "0,/^[[:space:]]*snapshotter = 'overlayfs'$/s//    snapshotter = 'native'/" /etc/containerd/config.toml
sed -Ei "s#^([[:space:]]*sandbox = ).*#\1'${PAUSE_IMAGE}'#" /etc/containerd/config.toml
sed -Ei "s#^([[:space:]]*SystemdCgroup = ).*#\1false#" /etc/containerd/config.toml

if ! grep -Eq "^[[:space:]]*snapshotter = 'native'$" /etc/containerd/config.toml; then
  echo "containerd snapshotter was not updated to native" >&2
  grep -n "snapshotter" /etc/containerd/config.toml >&2 || true
  exit 1
fi

cat >/etc/crictl.yaml <<EOF_CRICTL
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF_CRICTL

swapoff -a || true
rm -f /var/lib/swap /swap.img || true
modprobe overlay || true
modprobe br_netfilter || true
sysctl -w net.ipv4.ip_forward=1 || true
sysctl -w net.bridge.bridge-nf-call-iptables=1 || true
sysctl -w net.bridge.bridge-nf-call-ip6tables=1 || true

mkdir -p /var/lib/kubelet /var/log /var/run /etc/default
NODE_IP="$(hostname -i | cut -d' ' -f1)"
cat >/etc/kubernetes-resolv.conf <<'EOF_RESOLV'
nameserver 1.1.1.1
nameserver 8.8.8.8
options ndots:5
EOF_RESOLV
cat >/etc/default/kubelet <<EOF_KUBELET
KUBELET_EXTRA_ARGS="--node-ip=${NODE_IP}"
EOF_KUBELET

cat >/usr/local/bin/kubelet-launcher.sh <<'EOF_LAUNCHER'
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
EOF_LAUNCHER
chmod +x /usr/local/bin/kubelet-launcher.sh

cat >/usr/local/bin/kubelet-supervisor.sh <<'EOF_SUPERVISOR'
#!/usr/bin/env bash
set -euo pipefail

while true; do
  /usr/local/bin/kubelet-launcher.sh >>/var/log/kubelet.log 2>&1 || true
  sleep 2
done
EOF_SUPERVISOR
chmod +x /usr/local/bin/kubelet-supervisor.sh

pkill containerd || true
nohup containerd >/var/log/containerd.log 2>&1 &
timeout 30 sh -c "until crictl info >/dev/null 2>&1; do sleep 1; done"

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64) CTR_PLATFORM="linux/amd64" ;;
  arm64) CTR_PLATFORM="linux/arm64" ;;
  armhf) CTR_PLATFORM="linux/arm/v7" ;;
  *) CTR_PLATFORM="linux/$ARCH" ;;
esac

KUBEADM_VERSION="$(kubeadm version -o short)"
FLANNEL_MANIFEST_URL="https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml"

# containerd 2.x can fail CRI pulls in this nested-container lab. Pre-pull the
# kubeadm image set and flannel images through ctr's local path so kubeadm and
# kubelet do not hit the broken CRI pull path during bootstrap.
{
  echo "$PAUSE_IMAGE"
  kubeadm config images list --kubernetes-version "$KUBEADM_VERSION"
  echo "registry.k8s.io/coredns/coredns:${COREDNS_VERSION}"
  curl -fsSL "$FLANNEL_MANIFEST_URL" | awk '/image:[[:space:]]/ {print $2}'
} | awk '!seen[$0]++' | while read -r image; do
  [ -n "$image" ] || continue
  ctr -n k8s.io images pull --platform "$CTR_PLATFORM" --local "$image"
done >/var/log/bootstrap-image-prepull.log 2>&1 || {
  cat /var/log/bootstrap-image-prepull.log >&2 || true
  exit 1
}

if [ -f /var/run/kubelet-supervisor.pid ]; then
  kill "$(cat /var/run/kubelet-supervisor.pid)" 2>/dev/null || true
  rm -f /var/run/kubelet-supervisor.pid
fi
pkill kubelet || true
nohup /usr/local/bin/kubelet-supervisor.sh >/var/log/kubelet-supervisor.log 2>&1 </dev/null &
echo $! >/var/run/kubelet-supervisor.pid
