# Zonal GKE Standard cluster. The node settings live on the default pool
# (no remove_default_node_pool) so creation never briefly needs extra vCPUs.
resource "google_container_cluster" "this" {
  name       = var.name
  location   = var.zone
  network    = var.network
  subnetwork = var.subnetwork

  initial_node_count  = var.node_count
  deletion_protection = false

  node_config {
    machine_type = var.machine_type
    disk_size_gb = 30
    disk_type    = "pd-standard"
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  # VPC-native; GKE picks the pod and service ranges
  ip_allocation_policy {}

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.admin_cidrs
      content {
        cidr_block   = cidr_blocks.value
        display_name = cidr_blocks.key == 0 ? "you" : "shared-${cidr_blocks.key}"
      }
    }
  }
}
