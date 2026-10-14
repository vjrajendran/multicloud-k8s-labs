variable "project" {
  description = "The sandbox's project ID"
  type        = string
}

variable "region" {
  description = "Pluralsight GCP sandboxes allow us-east1, us-west1, us-central1, europe-west1, australia-southeast1"
  type        = string
  default     = "us-central1"

  validation {
    condition     = contains(["us-east1", "us-west1", "us-central1", "europe-west1", "australia-southeast1"], var.region)
    error_message = "Pluralsight GCP sandboxes allow us-east1, us-west1, us-central1, europe-west1, australia-southeast1."
  }
}

variable "kubeadm_clusters" {
  description = "kubeadm clusters (master1 + client1 + client2 VMs)"
  type        = number
  default     = 2
}

variable "managed_clusters" {
  description = "GKE Standard clusters (Autopilot isn't allowed)"
  type        = number
  default     = 0
}

variable "managed_node_count" {
  description = "Nodes per GKE cluster"
  type        = number
  default     = 2
}

variable "machine_type" {
  description = "Every node. e2-medium = 2 vCPU / 4 GB"
  type        = string
  default     = "e2-medium"
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
