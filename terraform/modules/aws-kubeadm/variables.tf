variable "name" {
  description = "Cluster name, e.g. aws1-k1 - used for tags and the security group"
  type        = string
}

variable "ami_id" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "key_name" {
  type = string
}

variable "private_key" {
  description = "Key for the AWS key pair - used to bootstrap master1 and for master1 -> workers"
  type        = string
  sensitive   = true
}

variable "admin_cidrs" {
  description = "Where SSH and the Kubernetes API are reachable from (you + shared users)"
  type        = list(string)
}

variable "master_instance_type" {
  type = string
}

variable "worker_instance_type" {
  type = string
}

variable "root_volume_size" {
  type = number
}

variable "repo_url" {
  type = string
}

variable "repo_branch" {
  type = string
}

variable "cloud_lb" {
  description = "Prepare the nodes for the AWS cloud controller (LoadBalancer Services)"
  type        = bool
  default     = false
}

variable "vpc_cidr" {
  description = "CIDR of the VPC - other clusters in it may reach this API server"
  type        = string
}
