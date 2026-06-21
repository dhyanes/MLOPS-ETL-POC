output "master_public_ip" {
  value = aws_instance.master.public_ip
}

output "worker_public_ips" {
  value = aws_instance.worker[*].public_ip
}

output "ssh_master" {
  value = "ssh ubuntu@${aws_instance.master.public_ip}"
}

output "fetch_kubeconfig" {
  description = "Run this locally once the master has finished bootstrapping (~3-5 min after apply) to pull a working kubeconfig"
  value       = "aws s3 cp s3://${var.kubeconfig_bucket}/kubeconfig/admin.conf ./kubeconfig.yaml && sed -i.bak 's/127.0.0.1\\|10\\.0\\.[0-9]*\\.[0-9]*/${aws_instance.master.public_ip}/' ./kubeconfig.yaml"
}
