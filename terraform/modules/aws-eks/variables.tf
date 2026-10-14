variable "name" {
  description = "Cluster name, e.g. aws1-eks1"
  type        = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "admin_cidrs" {
  description = "Where the public API endpoint is reachable from (you + shared users)"
  type        = list(string)
}

variable "node_count" {
  type = number
}

variable "instance_type" {
  type = string
}
