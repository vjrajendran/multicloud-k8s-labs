variable "name" {
  description = "Cluster name, e.g. azure1-k1"
  type        = string
}

variable "location" {
  type = string
}

variable "resource_group" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "public_key" {
  type = string
}

variable "private_key" {
  type      = string
  sensitive = true
}

variable "master_size" {
  type = string
}

variable "worker_size" {
  type = string
}

variable "repo_url" {
  type = string
}

variable "repo_branch" {
  type = string
}
