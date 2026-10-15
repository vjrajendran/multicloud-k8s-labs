locals {
  worker_names = ["client1", "client2"] # deploy.sh / inventory expect exactly these two

  # The AWS cloud controller finds "its" instances and security group by this tag
  cluster_tag = var.cloud_lb ? { "kubernetes.io/cluster/${var.name}" = "owned" } : {}
  node_sgs    = concat([aws_security_group.k8s.id], aws_security_group.ccm[*].id)
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
    description = "Kubernetes API from inside the VPC (e.g. Argo CD on a hub cluster)"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
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
  vpc_security_group_ids = local.node_sgs
  iam_instance_profile   = var.cloud_lb ? aws_iam_instance_profile.ccm[0].name : null

  # 2 hops: pods (like the cloud controller) can reach the instance metadata service
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }

  tags = merge(local.cluster_tag, {
    Name    = "${var.name}-${local.worker_names[count.index]}"
    Cluster = var.name
    Role    = "worker"
  })
}

resource "aws_instance" "master" {
  ami                    = var.ami_id
  instance_type          = var.master_instance_type
  key_name               = var.key_name
  vpc_security_group_ids = local.node_sgs
  iam_instance_profile   = var.cloud_lb ? aws_iam_instance_profile.ccm[0].name : null

  # 2 hops: pods (like the cloud controller) can reach the instance metadata service
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }

  tags = merge(local.cluster_tag, {
    Name    = "${var.name}-master1"
    Cluster = var.name
    Role    = "control-plane"
  })
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

# ---------------------------------------------------------------
# AWS cloud controller support (var.cloud_lb)
#
# kubeadm has no cloud integration of its own. With these, up.sh installs the
# AWS cloud controller manager (k8s/aws-cloud-controller-manager.yaml) and a
# Service of type LoadBalancer creates a real AWS load balancer - like EKS.
# ---------------------------------------------------------------

# The controller adds its load balancer rules here. No ingress blocks on
# purpose, so Terraform never removes the rules it adds.
resource "aws_security_group" "ccm" {
  count = var.cloud_lb ? 1 : 0

  name_prefix = "${var.name}-lb-"
  description = "Rules managed by the Kubernetes AWS cloud controller for ${var.name}"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.cluster_tag

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role" "ccm" {
  count       = var.cloud_lb ? 1 : 0
  name_prefix = "${var.name}-ccm-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# What the cloud controller needs for load balancers and node information
resource "aws_iam_role_policy" "ccm" {
  count = var.cloud_lb ? 1 : 0
  name  = "cloud-controller-manager"
  role  = aws_iam_role.ccm[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeTags",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceTopology",
        "ec2:DescribeRegions",
        "ec2:DescribeRouteTables",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSubnets",
        "ec2:DescribeVpcs",
        "ec2:CreateSecurityGroup",
        "ec2:CreateTags",
        "ec2:DeleteSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:ModifyInstanceAttribute",
        "elasticloadbalancing:*",
        "iam:CreateServiceLinkedRole",
        "kms:DescribeKey",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "ccm" {
  count       = var.cloud_lb ? 1 : 0
  name_prefix = "${var.name}-ccm-"
  role        = aws_iam_role.ccm[0].name
}
