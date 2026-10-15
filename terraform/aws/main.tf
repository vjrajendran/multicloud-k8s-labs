# ---------------------------------------------------------------
# Lookups
# ---------------------------------------------------------------

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_vpc" "default" {
  default = true
}

# EKS rejects a few zones for its control plane
data "aws_availability_zones" "eks" {
  state            = "available"
  exclude_zone_ids = ["use1-az3", "usw2-az4"]
}

data "aws_subnets" "eks" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }

  filter {
    name   = "availability-zone"
    values = data.aws_availability_zones.eks.names
  }
}

data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  admin_cidr  = var.admin_cidr != "" ? var.admin_cidr : "${chomp(data.http.my_ip.response_body)}/32"
  admin_cidrs = distinct(concat([local.admin_cidr], var.shared_cidrs))
  kubeadm     = [for i in range(var.kubeadm_clusters) : "${terraform.workspace}-k${i + 1}"]
  managed     = [for i in range(var.managed_clusters) : "${terraform.workspace}-eks${i + 1}"]
  instances   = var.kubeadm_clusters * 3 + var.managed_clusters * var.managed_node_count
}

# Pluralsight: no more than 9 concurrent instances (stopped ones count)
resource "terraform_data" "capacity" {
  input = local.instances

  lifecycle {
    precondition {
      condition     = local.instances <= 9
      error_message = "This needs ${local.instances} EC2 instances (3 per kubeadm cluster + ${var.managed_node_count} per EKS cluster); a Pluralsight AWS sandbox allows 9."
    }
  }
}

# ---------------------------------------------------------------
# SSH key for the kubeadm clusters in this sandbox
# ---------------------------------------------------------------

resource "tls_private_key" "lab" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "lab" {
  key_name_prefix = "${terraform.workspace}-"
  public_key      = tls_private_key.lab.public_key_openssh
}

resource "local_sensitive_file" "private_key" {
  filename        = "${path.root}/../../keys/${terraform.workspace}.pem"
  content         = tls_private_key.lab.private_key_openssh
  file_permission = "0400"
}

# ---------------------------------------------------------------
# Clusters
# ---------------------------------------------------------------

module "kubeadm" {
  source   = "../modules/aws-kubeadm"
  for_each = toset(local.kubeadm)

  name                 = each.key
  ami_id               = data.aws_ami.ubuntu.id
  vpc_id               = data.aws_vpc.default.id
  key_name             = aws_key_pair.lab.key_name
  private_key          = tls_private_key.lab.private_key_openssh
  admin_cidrs          = local.admin_cidrs
  master_instance_type = var.instance_type
  worker_instance_type = var.instance_type
  root_volume_size     = var.root_volume_size
  repo_url             = var.repo_url
  repo_branch          = var.repo_branch
  cloud_lb             = var.cloud_lb
  vpc_cidr             = data.aws_vpc.default.cidr_block

  depends_on = [terraform_data.capacity]
}

module "eks" {
  source   = "../modules/aws-eks"
  for_each = toset(local.managed)

  name          = each.key
  subnet_ids    = data.aws_subnets.eks.ids
  admin_cidrs   = local.admin_cidrs
  node_count    = var.managed_node_count
  instance_type = var.instance_type

  depends_on = [terraform_data.capacity]
}
