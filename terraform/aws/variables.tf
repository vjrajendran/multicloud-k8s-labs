variable "region" {
  description = "Pluralsight AWS sandboxes only allow us-east-1 and us-west-2"
  type        = string
  default     = "us-east-1"

  validation {
    condition     = contains(["us-east-1", "us-west-2"], var.region)
    error_message = "Pluralsight AWS sandboxes only allow us-east-1 and us-west-2."
  }
}

variable "kubeadm_clusters" {
  description = "kubeadm clusters (master1 + client1 + client2 on EC2)"
  type        = number
  default     = 3
}

variable "managed_clusters" {
  description = "EKS clusters"
  type        = number
  default     = 0
}

variable "managed_node_count" {
  description = "Nodes per EKS cluster"
  type        = number
  default     = 2
}

variable "instance_type" {
  description = "Every node. Pluralsight allows t2/t3/t3a/t4g in micro, small and medium; kubeadm needs 2 vCPU on master1"
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size" {
  description = "GB per kubeadm node (Pluralsight max is 100)"
  type        = number
  default     = 20
}

variable "admin_cidr" {
  description = "CIDR allowed to reach SSH and the Kubernetes APIs. Empty = auto-detect your public IP."
  type        = string
  default     = ""
}

variable "repo_url" {
  description = "Ansible repo cloned onto each kubeadm master1 (its deploy.sh must support CLUSTER_KEY mode)"
  type        = string
  default     = "https://github.com/rvinodrajendran/k8-cluster-automation.git"
}

variable "repo_branch" {
  type    = string
  default = "main"
}

variable "shared_cidrs" {
  description = "Extra CIDRs (people you share the clusters with) - up.sh fills this from users.txt"
  type        = list(string)
  default     = []
}
