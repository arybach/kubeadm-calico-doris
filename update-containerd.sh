#!/bin/bash

set -euo pipefail

# Usage check
if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <certificate-file-name> <certificate-host-name> (e.g., doris.crt doris.192.168.56.240.nip.io)"
  exit 1
fi

CERT_NAME="$1"
CERT_HOST="$2"
CERT_PATH="./${CERT_NAME}"
USER="vagrant"

# Load environment variables from config.env
source ./config.env

# Retrieve SSH keys for all nodes
WORKER1_KEY=$(vagrant ssh-config worker1 | awk '$1 == "IdentityFile" {print $2}')
WORKER2_KEY=$(vagrant ssh-config worker2 | awk '$1 == "IdentityFile" {print $2}')
MASTER_KEY=$(vagrant ssh-config master  | awk '$1 == "IdentityFile" {print $2}')

echo "[*] Uploading cert to worker1 ($WORKER1_IP)..."
scp -i "$WORKER1_KEY" -o StrictHostKeyChecking=no "$CERT_PATH" ${USER}@${WORKER1_IP}:/tmp/"$CERT_NAME"

echo "[*] Uploading cert to worker2 ($WORKER2_IP)..."
scp -i "$WORKER2_KEY" -o StrictHostKeyChecking=no "$CERT_PATH" ${USER}@${WORKER2_IP}:/tmp/"$CERT_NAME"

echo "[*] Uploading cert to master ($MASTER_IP)..."
scp -i "$MASTER_KEY" -o StrictHostKeyChecking=no "$CERT_PATH" ${USER}@${MASTER_IP}:/tmp/"$CERT_NAME"

for HOST in worker1:$WORKER1_IP:$WORKER1_KEY worker2:$WORKER2_IP:$WORKER2_KEY master:$MASTER_IP:$MASTER_KEY; do
  NAME=$(echo $HOST | cut -d: -f1)
  IP=$(echo $HOST | cut -d: -f2)
  KEY=$(echo $HOST | cut -d: -f3)

  echo "[*] Installing ${CERT_NAME} and restarting containerd on $NAME..."
  ssh -i "$KEY" -o StrictHostKeyChecking=no ${USER}@${IP} <<EOF
    sudo mv /tmp/${CERT_NAME} /usr/local/share/ca-certificates/${CERT_NAME}
    sudo update-ca-certificates
    sudo systemctl restart containerd
EOF
done

echo "[✓] ${CERT_NAME} installed and containerd restarted on all nodes."
