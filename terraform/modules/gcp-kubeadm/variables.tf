variable "name" {
  description = "Cluster name, e.g. gcp1-k1"
  type        = string
}

variable "zone" {
  type = string
}

variable "subnetwork" {
  type = string
}

variable "machine_type" {
  type = string
}

variable "public_key" {
  type = string
}

variable "private_key" {
  type      = string
  sensitive = true
}

variable "repo_url" {
  type = string
}

variable "repo_branch" {
  type = string
}
