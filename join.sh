#!/bin/bash -eu

MASTER_IP="10.1.10.7"
NODE_IP="$1"

# === WAIT FOR API SERVER ===
echo "[i] waiting for control plane to become ready..."
until curl -k https://${MASTER_IP}:6443/healthz 2>/dev/null | grep -q ok; do
  sleep 3
done

# === CHECK IF NODE ALREADY JOINED ===
if [ -f /var/lib/kubelet/pki/kubelet-client-current.pem ]; then
  echo "[i] Node already joined the cluster. Skipping join step."
  exit 0
fi

# === WAIT FOR JOIN-COMMAND.SH ===
echo "[i] waiting for master to generate join-command.sh..."
while [ ! -f /vagrant/join-command.sh ]; do
  sleep 2
done

# === INSTALL BASE DEPENDENCIES AND CONTAINERD ===
echo "[i] installing base packages"
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg jq containerd

# === CONFIGURE CONTAINERD ===
echo "[i] configuring containerd"
sudo mkdir -p /etc/containerd
containerd config default | sed -e "s/SystemdCgroup = false/SystemdCgroup = true/" | sudo tee /etc/containerd/config.toml
sudo systemctl restart containerd

# === INSTALL KUBERNETES TOOLS ===
echo "[i] installing Kubernetes tools"
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# === RESET NODE ===
echo "[i] resetting kubeadm/kubelet state"
sudo kubeadm reset -f
sudo rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd /etc/cni /opt/cni /var/lib/cni /run/flannel
sudo systemctl daemon-reexec
sudo systemctl restart containerd

# === KERNEL MODULES AND SYSCTL ===
echo "[i] configuring kernel modules and sysctl"
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
sudo sysctl --system

# === KUBELET CONFIG ===
echo "KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}" | sudo tee /etc/default/kubelet
sudo systemctl daemon-reexec
sudo systemctl stop kubelet || true
sudo systemctl disable kubelet || true

# === OPTIONAL: METALLB ROUTE ===
echo "[i] configuring route for MetalLB"
IFACE_NAME=$(ip -o addr show | grep '192.168.56' | awk '{print $2}' | head -n1)
if [ -n "$IFACE_NAME" ]; then
  echo "[i] using interface $IFACE_NAME"
  sudo ip route add 192.168.56.0/24 dev "$IFACE_NAME" || true
else
  echo "[!] No interface found for MetalLB range" >&2
fi

# === PREPARE HOSTPATH DIRECTORIES FOR DORIS ===
echo "[i] preparing hostPath directories for Doris FE/BE"
sudo mkdir -p /mnt/data/doris-fe
sudo mkdir -p /mnt/data/doris-be
sudo chown -R 1000:1000 /mnt/data/doris-fe /mnt/data/doris-be

# === JOIN CLUSTER ===
echo "[i] joining the cluster..."
sudo bash /vagrant/join-command.sh

# === DONE ===
echo "[✓] kubeadm join completed — kubelet will be started by kubeadm"