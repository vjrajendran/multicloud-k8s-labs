locals {
  worker_names = ["client1", "client2"] # deploy.sh / inventory expect exactly these two
}

# ---------------------------------------------------------------
# Security group
# ---------------------------------------------------------------

resource "aws_security_group" "k8s" {
  name_prefix = "${var.name}-"
  description = "k8s lab cluster ${var.name}"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH from you and shared users"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.admin_cidrs
  }

  ingress {
    description = "Kubernetes API from you and shared users"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = var.admin_cidrs
  }

  ingress {
    description = "All traffic between nodes of this cluster (kubelet, etcd, flannel VXLAN, NodePorts)"
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

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------
# Instances
# ---------------------------------------------------------------

resource "aws_instance" "workers" {
  count = length(local.worker_names)

  ami                    = var.ami_id
  instance_type          = var.worker_instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.k8s.id]

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }

  tags = {
    Name    = "${var.name}-${local.worker_names[count.index]}"
    Cluster = var.name
    Role    = "worker"
  }
}

resource "aws_instance" "master" {
  ami                    = var.ami_id
  instance_type          = var.master_instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.k8s.id]

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }

  tags = {
    Name    = "${var.name}-master1"
    Cluster = var.name
    Role    = "control-plane"
  }
}

# ---------------------------------------------------------------
# Bootstrap: kubeadm via deploy.sh on master1
# ---------------------------------------------------------------

module "bootstrap" {
  source = "../kubeadm-bootstrap"

  master_public_ip   = aws_instance.master.public_ip
  master_private_ip  = aws_instance.master.private_ip
  worker_private_ips = aws_instance.workers[*].private_ip
  instance_ids       = concat([aws_instance.master.id], aws_instance.workers[*].id)
  private_key        = var.private_key
  repo_url           = var.repo_url
  repo_branch        = var.repo_branch
}
