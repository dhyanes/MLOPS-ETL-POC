terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ---------------------------------------------------------------------------
# Networking — single AZ, single public subnet. Fine for a PoC; for production
# split into private subnets for nodes + a NAT gateway.
# ---------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block               = var.public_subnet_cidr
  availability_zone        = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch  = true
  tags = { Name = "${var.name_prefix}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${var.name_prefix}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# Security group — open within the cluster, scoped externally to allowed_ssh_cidr
# ---------------------------------------------------------------------------

resource "aws_security_group" "cluster" {
  name_prefix = "${var.name_prefix}-sg-"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "Kubernetes API server"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "NodePort range — Airflow/Argo/KServe UIs and test endpoints"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # All traffic between cluster members (pod network, kubelet, etcd, etc.)
  ingress {
    description = "Intra-cluster traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-sg" }
}

# ---------------------------------------------------------------------------
# IAM — lets nodes exchange the kubeadm join command via SSM Parameter Store,
# and lets the master upload admin.conf to S3 for you to fetch locally.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.name_prefix}-node-role"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

locals {
  dvc_bucket = var.dvc_bucket != "" ? var.dvc_bucket : var.kubeconfig_bucket
}

data "aws_iam_policy_document" "node_policy" {
  statement {
    sid       = "JoinCommandParam"
    actions   = ["ssm:PutParameter", "ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.aws_region}:*:parameter/${var.name_prefix}-cluster/*"]
  }
  statement {
    sid       = "KubeconfigUpload"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["arn:aws:s3:::${var.kubeconfig_bucket}/kubeconfig/*"]
  }
  statement {
    sid       = "DvcRemoteAccess"
    actions   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.dvc_bucket}/*"]
  }
  statement {
    sid       = "DvcRemoteListBucket"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.dvc_bucket}"]
  }
}

resource "aws_iam_role_policy" "node" {
  name   = "${var.name_prefix}-node-policy"
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.node_policy.json
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.name_prefix}-node-profile"
  role = aws_iam_role.node.name
}

# ---------------------------------------------------------------------------
# AMI — Ubuntu 22.04 LTS
# ---------------------------------------------------------------------------

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---------------------------------------------------------------------------
# Instances
# ---------------------------------------------------------------------------

resource "aws_instance" "master" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.master_instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.cluster.id]
  key_name                    = var.key_name
  iam_instance_profile        = aws_iam_instance_profile.node.name
  associate_public_ip_address = true

  root_block_device {
    volume_size = 40
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/scripts/master.sh.tpl", {
    pod_network_cidr   = var.pod_network_cidr
    kubernetes_version = var.kubernetes_version
    aws_region         = var.aws_region
    name_prefix        = var.name_prefix
    kubeconfig_bucket  = var.kubeconfig_bucket
  })

  tags = { Name = "${var.name_prefix}-master", Role = "master" }
}

resource "aws_instance" "worker" {
  count                       = var.worker_count
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.worker_instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.cluster.id]
  key_name                    = var.key_name
  iam_instance_profile        = aws_iam_instance_profile.node.name
  associate_public_ip_address = true

  root_block_device {
    volume_size = 60
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/scripts/worker.sh.tpl", {
    kubernetes_version = var.kubernetes_version
    aws_region         = var.aws_region
    name_prefix        = var.name_prefix
  })

  tags = { Name = "${var.name_prefix}-worker-${count.index}", Role = "worker" }

  depends_on = [aws_instance.master]
}
