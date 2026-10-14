variable "name" {
  description = "Cluster name, e.g. azure1-aks1"
  type        = string
}

variable "location" {
  type = string
}

variable "resource_group" {
  type = string
}

variable "admin_cidrs" {
  description = "Where the API server is reachable from (you + shared users)"
  type        = list(string)
}

variable "node_count" {
  type = number
}

variable "node_size" {
  type = string
}
