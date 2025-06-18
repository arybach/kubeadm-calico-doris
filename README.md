# vagrant-k8s calico

This repo spins up a k8s cluster with calico on VirtualBox VMs using Vagrant. Local setup with Vagrant helps debug k8s deployments with self-signed or staging TLS certificates which require full access to nodes and updates to containerd (and are no longer feasible on DigitalOcean, for example — no SSH access, managed LoadBalancer will only mount production TLS and no containerd update even via deployment spec). 

The repo deploys cert-manager, MetalLB, Gitea (light-weight alternative to GitLab for CI/CD), and a Doris cluster with self-signed certs. Your app deployment part is up to you (might require even more CPU — 16+ cores and RAM — 64GB+ and an additional worker node). 

It is tested for Kubernetes 1.32 version and should work with newer versions, although some YAML definitions might need to be adjusted. The repo should work on any amd64 machine running Debian Linux with sufficient resources (tweak CPU and RAM node settings in `Vagrantfile`). It has not been tested with KVM-libvirt hypervisor, and switching to Cilium CNI plugin will most likely fail with VirtualBox. 

Repo structure is flat for ease of navigation and the code is only suitable for local development (not for deployment on publicly-accessible infrastructure).

## To start
```bash
vagrant up
# only needed once
VBoxManage hostonlyif create
VBoxManage hostonlyif ipconfig vboxnet0 --ip 192.168.56.1

# once k8s deployed - fetch kube config !!!
vagrant ssh master -- sudo cat /etc/kubernetes/admin.conf > ~/.kube/config

# check
kubectl get pods -n kube-system -l k8s-app=calico-node -o wide
# test with nginx 
kubectl create deploy nginx --image=nginx
kubectl expose deploy nginx --port=80
kubectl get pods,svc
```

### If Vagrant fails with: "The IP address configured for the host-only network is not within the allowed ranges"
```bash
echo "* 10.1.10.0/24 192.168.56.0/21" | sudo tee /etc/vbox/networks.conf
```

### Disable KVM extensions on AMD (non-Intel) boxes
```bash
sudo systemctl stop libvirtd
sudo rmmod kvm_amd
sudo rmmod kvm

# to blacklist (optional):
echo "blacklist kvm_amd" | sudo tee /etc/modprobe.d/blacklist-kvm.conf
echo "blacklist kvm"     | sudo tee -a /etc/modprobe.d/blacklist-kvm.conf
```

## Requirements
- virtualbox-7.0
- vagrant
- helm
- ansible
- docker

### Install requirements

#### virtualbox-7.0
```bash
wget -q https://www.virtualbox.org/download/oracle_vbox_2016.asc -O- | sudo apt-key add -
wget -q https://www.virtualbox.org/download/oracle_vbox.asc -O- | sudo apt-key add -
sudo add-apt-repository "deb [arch=amd64] http://download.virtualbox.org/virtualbox/debian $(lsb_release -cs) contrib"
sudo apt update
sudo apt install virtualbox-7.0
```

#### vagrant
```bash
wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install vagrant
```

#### ansible
```bash
sudo apt install ansible
python3 -m venv ~/ansible-env
source ~/ansible-env/bin/activate
pip install kubernetes jmespath
```

### Deploy cert-manager and MetalLB
```bash
ansible-playbook deploy-certmanager.yml
# then check 
kubectl get all -n cert-manager
kubectl get all -n metallb-system
```

### Export required S3 variables (used by Gitea)
```bash
export AWS_ACCESS_KEY_ID="...."
export AWS_SECRET_ACCESS_KEY="...."

# additional variables are set in deploy-gitea.yml
S3_BUCKET="...."
S3_REGION="...."
S3_ENDPOINT="...."
```

### Deploy Gitea
```bash
ansible-playbook deploy-gitea.yml
```

### Push images to https://192.168.56.240.nip.io (org: doris, repo: doris)
```bash
export GITEA_ROOT_PASSWORD='Gitea_YourSecurePassword'

# Make sure 192.168.56.240.nip.io is added to insecure hosts in /etc/hosts
{
  "insecure-registries": ["192.168.56.240.nip.io", "doris.192.168.56.240.nip.io"]
}

# Extract the certs
kubectl get secret 192.168.56.240.nip.io-tls -n gitea -o jsonpath='{.data.tls\.crt}' | base64 -d > gitea.crt
sudo mkdir -p /etc/docker/certs.d/192.168.56.240.nip.io
sudo cp gitea.crt /etc/docker/certs.d/192.168.56.240.nip.io/gitea.crt
sudo systemctl restart docker

kubectl get secret doris.192.168.56.240.nip.io-tls -n doris -o jsonpath='{.data.tls\.crt}' | base64 -d > doris.crt
sudo mkdir -p /etc/docker/certs.d/doris.192.168.56.240.nip.io
sudo cp doris.crt /etc/docker/certs.d/doris.192.168.56.240.nip.io/doris.crt
sudo systemctl restart docker

# Update certs on nodes
./update-containerd.sh gitea.crt 192.168.56.240.nip.io
./update-containerd.sh doris.crt doris.192.168.56.240.nip.io

# Test login
echo "$GITEA_ROOT_PASSWORD" | docker login https://192.168.56.240.nip.io -u Gitea_Admin --password-stdin
# or
docker login https://192.168.56.240.nip.io -u Gitea_Admin -p "$GITEA_ROOT_PASSWORD"

docker tag your_app:latest 192.168.56.240.nip.io/your_app/your_app:main
```

### Deploy your app
```bash
# Make sure to create group and repo in Gitea UI (https://192.168.56.240.nip.io)
docker push 192.168.56.240.nip.io/your_app/your_app:main
```

### Debug app
```bash
kubectl run debug-pod --rm -it \
  --image=192.168.56.240.nip.io/your_app/your_app:main \
  --namespace=your_app \
  -- /bin/bash

# For Python app:
/usr/local/bin/python -m your_app
```

### Deploy Doris (requires 16+ cores and 64GB+ memory)
```bash
sudo sysctl -w vm.max_map_count=2000000
ansible-playbook deploy-doris.yml
```

### Validate Doris setup
```bash
kubectl exec -it -n doris doris-cluster-fe-0 -- bash
mysql -h 127.0.0.1 -P 9030 -u root
SHOW BACKENDS\G
```

> Doris UI should be accessible at [https://doris.192.168.56.240.nip.io](https://doris.192.168.56.240.nip.io) (default user: `root`, empty password)

![alt text](image.png)

## Cleanup
```bash
vagrant destroy -f