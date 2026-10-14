variable "name" {
  description = "Cluster name, e.g. gcp1-gke1"
  type        = string
}

variable "zone" {
  description = "Zonal cluster - a regional one would triple the nodes"
  type        = string
}

variable "network" {
  type = string
}

variable "subnetwork" {
  type = string
}

variable "admin_cidrs" {
  description = "Where the API server is reachable from (you + shared users)"
  type        = list(string)
}

variable "node_count" {
  type = number
}

variable "machine_type" {
  type = string
}
