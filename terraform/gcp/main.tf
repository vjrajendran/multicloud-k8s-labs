# ---------------------------------------------------------------
# APIs and lookups
# ---------------------------------------------------------------

resource "google_project_service" "compute" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "container" {
  count = var.managed_clusters > 0 ? 1 : 0

  service            = "container.googleapis.com"
  disable_on_destroy = false
}

data "google_compute_zones" "available" {
  region = var.region

  depends_on = [google_project_service.compute]
}

data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  zone        = data.google_compute_zones.available.names[0]
  admin_cidr  = var.admin_cidr != "" ? var.admin_cidr : "${chomp(data.http.my_ip.response_body)}/32"
  admin_cidrs = distinct(concat([local.admin_cidr], var.shared_cidrs))
  kubeadm     = [for i in range(var.kubeadm_clusters) : "${terraform.workspace}-k${i + 1}"]
  managed     = [for i in range(var.managed_clusters) : "${terraform.workspace}-gke${i + 1}"]

  # vCPUs per allowed shared-core / small machine type
  vcpus      = { "e2-micro" = 2, "e2-small" = 2, "e2-medium" = 2, "e2-standard-2" = 2 }
  instances  = var.kubeadm_clusters * 3 + var.managed_clusters * var.managed_node_count
  vcpu_total = local.instances * lookup(local.vcpus, var.machine_type, 99)
}

# Pluralsight: max 10 instances and 12 vCPUs, GKE nodes included
resource "terraform_data" "capacity" {
  input = [local.instances, local.vcpu_total]

  lifecycle {
    precondition {
      condition     = contains(keys(local.vcpus), var.machine_type)
      error_message = "machine_type must be one of ${join(", ", keys(local.vcpus))} (8 GB per instance max)."
    }
    precondition {
      condition     = local.instances <= 10 && local.vcpu_total <= 12
      error_message = "This needs ${local.instances} instances / ${local.vcpu_total} vCPUs; a Pluralsight GCP sandbox allows 10 / 12. A kubeadm cluster uses 6 vCPU, each GKE node 2."
    }
  }
}

# ---------------------------------------------------------------
# Network
# ---------------------------------------------------------------

resource "google_compute_network" "lab" {
  name                    = "${terraform.workspace}-net"
  auto_create_subnetworks = false

  depends_on = [google_project_service.compute]
}

resource "google_compute_subnetwork" "nodes" {
  name          = "${terraform.workspace}-nodes"
  network       = google_compute_network.lab.id
  region        = var.region
  ip_cidr_range = "10.30.0.0/24"
}

resource "google_compute_firewall" "internal" {
  name          = "${terraform.workspace}-internal"
  network       = google_compute_network.lab.id
  source_ranges = [google_compute_subnetwork.nodes.ip_cidr_range]

  allow {
    protocol = "all"
  }
}

resource "google_compute_firewall" "admin" {
  name          = "${terraform.workspace}-admin"
  network       = google_compute_network.lab.id
  source_ranges = local.admin_cidrs

  allow {
    protocol = "tcp"
    ports    = ["22", "6443"]
  }
}

# ---------------------------------------------------------------
# SSH key for the kubeadm clusters in this sandbox
# ---------------------------------------------------------------

resource "tls_private_key" "lab" {
  algorithm = "ED25519"
}

resource "local_sensitive_file" "private_key" {
  filename        = "${path.root}/../../keys/${terraform.workspace}.pem"
  content         = tls_private_key.lab.private_key_openssh
  file_permission = "0400"
}

# ---------------------------------------------------------------
# Clusters
# ---------------------------------------------------------------

module "kubeadm" {
  source   = "../modules/gcp-kubeadm"
  for_each = toset(local.kubeadm)

  name         = each.key
  zone         = local.zone
  subnetwork   = google_compute_subnetwork.nodes.id
  machine_type = var.machine_type
  public_key   = tls_private_key.lab.public_key_openssh
  private_key  = tls_private_key.lab.private_key_openssh
  repo_url     = var.repo_url
  repo_branch  = var.repo_branch

  depends_on = [terraform_data.capacity, google_compute_firewall.internal, google_compute_firewall.admin]
}

module "gke" {
  source   = "../modules/gcp-gke"
  for_each = toset(local.managed)

  name         = each.key
  zone         = local.zone
  network      = google_compute_network.lab.id
  subnetwork   = google_compute_subnetwork.nodes.id
  admin_cidrs  = local.admin_cidrs
  node_count   = var.managed_node_count
  machine_type = var.machine_type

  depends_on = [terraform_data.capacity, google_project_service.container]
}
