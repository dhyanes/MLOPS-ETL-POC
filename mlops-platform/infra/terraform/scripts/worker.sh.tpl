#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/mlops-bootstrap.log) 2>&1

KUBE_VERSION="${kubernetes_version}"
REGION="${aws_region}"
NAME_PREFIX="${name_prefix}"

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

# --- wait for the master to publish the join command via SSM ---------------
JOIN_CMD=""
for i in $(seq 1 60); do
  JOIN_CMD=$(aws ssm get-parameter \
    --region "$${REGION}" \
    --name "/$${NAME_PREFIX}-cluster/join-command" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text 2>/dev/null || true)
  if [ -n "$${JOIN_CMD}" ] && [ "$${JOIN_CMD}" != "None" ]; then
    break
  fi
  echo "Join command not published yet, retrying in 10s ($${i}/60)..."
  sleep 10
done

if [ -z "$${JOIN_CMD}" ] || [ "$${JOIN_CMD}" = "None" ]; then
  echo "Timed out waiting for join command" >&2
  exit 1
fi

eval "$${JOIN_CMD}"

echo "Worker bootstrap complete." > /var/log/mlops-bootstrap.done
