#!/bin/bash -eu
cd "$(dirname "$0")"
CONFIG_PATH="./config.env"
[ -f "$CONFIG_PATH" ] && export $(grep -v '^#' "$CONFIG_PATH" | xargs)

NODE_IP="${1:-$MASTER_IP}"
K8S_IFACE="${2:-$K8S_IFACE}"
METALLB_START="${3:-$METALLB_START}"
METALLB_END="${4:-$METALLB_END}"

if [[ -z "$NODE_IP" || -z "$K8S_IFACE" || -z "$METALLB_START" || -z "$METALLB_END" ]]; then
  echo "Usage: $0 <address> <interface> <ipstart> <ipstop>" >&2
  exit 1
fi

sudo snap install yq --channel=v4/stable
sudo apt-get update && sudo apt-get install -y moreutils jq

# Install Helm
echo "[i] installing Helm"
curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 /tmp/get_helm.sh
/tmp/get_helm.sh

# Kubectl aliases
echo "[i] setting up kubectl aliases"
curl -fsSL https://raw.githubusercontent.com/ahmetb/kubectl-aliases/master/.kubectl_aliases -o ~/.kubectl_aliases
echo '[ -f ~/.kubectl_aliases ] && source ~/.kubectl_aliases' >>~/.bashrc

# Kernel modules and sysctl
echo "[i] configuring networking"
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
sudo sysctl --system

# Install containerd
echo "[i] installing containerd"
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update && sudo apt-get install -y containerd.io

sudo mkdir -p /etc/containerd
containerd config default | \
  sed -e "s/SystemdCgroup = false/SystemdCgroup = true/g" | \
  sudo tee /etc/containerd/config.toml
sudo systemctl restart containerd

# Kubernetes tools
echo "[i] installing Kubernetes tools"
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# Init cluster
echo "[i] initializing cluster with kubeadm"
sudo kubeadm init \
  --apiserver-advertise-address="$NODE_IP" \
  --pod-network-cidr=192.168.0.0/16

mkdir -p "$HOME/.kube"
sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

echo "[i] waiting before applying Calico"
sleep 5

# Apply Calico manifest
CALICO_MANIFEST="/home/vagrant/calico.yaml"
curl -sSL https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml -o "$CALICO_MANIFEST"

echo "[i] patching Calico to disable IPIP and BGP"
sed -i 's/CALICO_IPV4POOL_IPIP: Always/CALICO_IPV4POOL_IPIP: Never/g' "$CALICO_MANIFEST"
sed -i '/bird-ready/d' "$CALICO_MANIFEST"
sed -i '/bird-live/d' "$CALICO_MANIFEST"
sed -i '/bird.ctl/d' "$CALICO_MANIFEST"

kubectl apply -f "$CALICO_MANIFEST"

# Remove taint to allow scheduling
kubectl taint node --all node-role.kubernetes.io/control-plane- || true

echo "[i] node info:"
kubectl get nodes -o wide

# Wait for API server
echo "[i] waiting for API server to become ready..."
until kubectl get --raw='/healthz' 2>/dev/null | grep -q ok; do
  sleep 3
done

# === Generate join command ===
echo "[i] generating join command"
kubeadm token create --print-join-command | sed 's|\\||g' > /vagrant/join-command.sh
chmod +x /vagrant/join-command.sh

# # 🔁 Force re-rsync from inside the master VM to update the host-mounted folder
# this might be needed for kvm-libvert hyperscaler (vs the Oracle VirtualBox)
# echo "[i] forcing host rsync update"
# touch /vagrant/.trigger_rsync
