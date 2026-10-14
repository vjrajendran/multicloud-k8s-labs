variable "resource_group" {
  description = "The sandbox's resource group (it can't create others). Empty = auto-detect."
  type        = string
  default     = ""
}

variable "location" {
  description = "Empty = the sandbox resource group's location"
  type        = string
  default     = ""
}

variable "kubeadm_clusters" {
  description = "kubeadm clusters (master1 + client1 + client2 VMs)"
  type        = number
  default     = 2
}

variable "managed_clusters" {
  description = "AKS clusters"
  type        = number
  default     = 0
}

variable "managed_node_count" {
  description = "Nodes per AKS cluster (Pluralsight max 3)"
  type        = number
  default     = 2
}

variable "master_size" {
  description = "kubeadm master1 - needs 2 vCPU"
  type        = string
  default     = "Standard_B2s"
}

variable "worker_size" {
  description = "kubeadm workers - 1 vCPU keeps 2 clusters under the 10 vCPU cap"
  type        = string
  default     = "Standard_B1ms"
}

variable "aks_node_size" {
  description = "AKS system pools need >= 2 vCPU and 4 GB"
  type        = string
  default     = "Standard_B2s"
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
