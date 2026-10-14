# Clone the Ansible repo on master1 and run deploy.sh (same on every cloud:
# Ubuntu 24.04, user "ubuntu", master1 reaches the workers on private IPs).

resource "terraform_data" "bootstrap" {
  triggers_replace = var.instance_ids

  connection {
    type        = "ssh"
    host        = var.master_public_ip
    user        = "ubuntu"
    private_key = var.private_key
    timeout     = "5m"
  }

  # Same key lets master1 reach the workers - no PEM pasting
  provisioner "file" {
    content     = var.private_key
    destination = "/home/ubuntu/.ssh/k8s_cluster_key"
  }

  # deploy.sh output also goes to ~/deploy.log on master1, because Terraform
  # may hide provisioner output when the connection uses a sensitive key.
  provisioner "remote-exec" {
    inline = [
      "set -e",
      "echo 'Waiting for cloud-init to finish (apt lock)...'",
      "cloud-init status --wait > /dev/null || true",
      "chmod 600 /home/ubuntu/.ssh/k8s_cluster_key",
      "sudo apt-get update -qq",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git",
      "rm -rf /home/ubuntu/k8-cluster-automation",
      "git clone --branch ${var.repo_branch} --depth 1 ${var.repo_url} /home/ubuntu/k8-cluster-automation",
      "chmod +x /home/ubuntu/k8-cluster-automation/deploy.sh",
      join(" ", [
        "MASTER_IP=${var.master_private_ip}",
        "CLIENT1_IP=${var.worker_private_ips[0]}",
        "CLIENT2_IP=${var.worker_private_ips[1]}",
        "CLUSTER_KEY=/home/ubuntu/.ssh/k8s_cluster_key",
        "bash -o pipefail -c '/home/ubuntu/k8-cluster-automation/deploy.sh 2>&1 | tee /home/ubuntu/deploy.log'",
      ]),
    ]
  }
}
