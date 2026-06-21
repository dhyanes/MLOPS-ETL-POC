#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/mlops-bootstrap.log) 2>&1

KUBE_VERSION="${kubernetes_version}"
POD_CIDR="${pod_network_cidr}"
REGION="${aws_region}"
NAME_PREFIX="${name_prefix}"
KUBECONFIG_BUCKET="${kubeconfig_bucket}"

# --- OS prep -----------------------------------------------------------
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

cat <<EOF >/etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat <<EOF >/etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

apt-get update -y
apt-get install -y ca-certificates curl gnupg apt-transport-https awscli jq

# --- containerd ----------------------------------------------------------
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y containerd.io
containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/' > /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# --- kubeadm / kubelet / kubectl -----------------------------------------
curl -fsSL https://pkgs.k8s.io/core:/stable:/v$${KUBE_VERSION}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$${KUBE_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

# --- kubeadm init ----------------------------------------------------------
PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

kubeadm init \
  --pod-network-cidr="$${POD_CIDR}" \
  --apiserver-advertise-address="$${PRIVATE_IP}" \
  --apiserver-cert-extra-sans="$${PUBLIC_IP}" \
  --node-name master

mkdir -p /home/ubuntu/.kube
cp -i /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
chown ubuntu:ubuntu /home/ubuntu/.kube/config
export KUBECONFIG=/etc/kubernetes/admin.conf

# --- CNI: Calico ----------------------------------------------------------
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml

# --- Allow scheduling on the master too (PoC convenience) -----------------
kubectl taint nodes master node-role.kubernetes.io/control-plane:NoSchedule- || true

# --- Publish join command for workers via SSM ------------------------------
JOIN_CMD=$(kubeadm token create --print-join-command)
aws ssm put-parameter \
  --region "$${REGION}" \
  --name "/$${NAME_PREFIX}-cluster/join-command" \
  --value "$${JOIN_CMD}" \
  --type SecureString \
  --overwrite

# --- Publish admin kubeconfig to S3 so you can fetch it locally -----------
# (rewrite the server address to the public IP so it's reachable from outside the VPC)
sed "s#server: https://$${PRIVATE_IP}:6443#server: https://$${PUBLIC_IP}:6443#" \
  /etc/kubernetes/admin.conf > /tmp/admin.conf
aws s3 cp /tmp/admin.conf "s3://$${KUBECONFIG_BUCKET}/kubeconfig/admin.conf" --region "$${REGION}"

# --- Install Helm (used by the platform install scripts) -------------------
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

echo "Master bootstrap complete." > /var/log/mlops-bootstrap.done
