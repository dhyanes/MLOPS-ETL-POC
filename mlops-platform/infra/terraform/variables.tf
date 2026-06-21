variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-south-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "pod_network_cidr" {
  description = "CIDR used by the Calico CNI for pod networking"
  type        = string
  default     = "192.168.0.0/16"
}

variable "kubernetes_version" {
  description = "Kubernetes minor version (must match a pkgs.k8s.io apt repo, e.g. 1.29)"
  type        = string
  default     = "1.29"
}

variable "key_name" {
  description = "Name of an EXISTING AWS EC2 key pair, used for SSH access"
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to reach SSH (22) and the K8s API/NodePort range. Restrict this to your own IP for anything beyond a quick PoC."
  type        = string
  default     = "0.0.0.0/0"
}

variable "master_instance_type" {
  type    = string
  default = "t3.large"
}

variable "worker_instance_type" {
  type    = string
  default = "t3.xlarge"
}

variable "worker_count" {
  description = "Number of worker nodes. 2 is enough to spread Airflow, Argo and KServe pods for a PoC."
  type        = number
  default     = 2
}

variable "kubeconfig_bucket" {
  description = "S3 bucket the master node uploads admin.conf to, so you can fetch a working kubeconfig locally. Can be the same bucket you use for DVC, in a different prefix."
  type        = string
}

variable "dvc_bucket" {
  description = "S3 bucket used as the DVC remote. Defaults to kubeconfig_bucket if left blank — set it explicitly if you're using a separate bucket for data/model artifacts."
  type        = string
  default     = ""
}

variable "name_prefix" {
  type    = string
  default = "mlops"
}
