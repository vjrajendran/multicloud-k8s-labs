variable "master_public_ip" {
  type = string
}

variable "master_private_ip" {
  type = string
}

variable "worker_private_ips" {
  description = "Exactly two - deploy.sh joins client1 and client2"
  type        = list(string)

  validation {
    condition     = length(var.worker_private_ips) == 2
    error_message = "deploy.sh expects exactly two workers."
  }
}

variable "private_key" {
  description = "SSH key accepted by all three nodes for user ubuntu"
  type        = string
  sensitive   = true
}

variable "instance_ids" {
  description = "Bootstrap re-runs when any of these change"
  type        = list(string)
}

variable "repo_url" {
  type = string
}

variable "repo_branch" {
  type = string
}
