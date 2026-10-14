locals {
  # deploy.sh / inventory expect master1 + exactly these two workers
  nodes = ["master1", "client1", "client2"]
}

resource "google_compute_instance" "node" {
  for_each = toset(local.nodes)

  name         = "${var.name}-${each.key}"
  zone         = var.zone
  machine_type = var.machine_type

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = 20
      type  = "pd-standard"
    }
  }

  # External IP on every node for apt / image pulls (no Cloud NAT needed)
  network_interface {
    subnetwork = var.subnetwork
    access_config {}
  }

  # Plain metadata SSH keys create the "ubuntu" user that deploy.sh expects
  metadata = {
    ssh-keys       = "ubuntu:${var.public_key}"
    enable-oslogin = "FALSE"
  }

  labels = {
    cluster = var.name
    role    = each.key == "master1" ? "control-plane" : "worker"
  }
}

module "bootstrap" {
  source = "../kubeadm-bootstrap"

  master_public_ip   = google_compute_instance.node["master1"].network_interface[0].access_config[0].nat_ip
  master_private_ip  = google_compute_instance.node["master1"].network_interface[0].network_ip
  worker_private_ips = [for n in ["client1", "client2"] : google_compute_instance.node[n].network_interface[0].network_ip]
  instance_ids       = [for n in local.nodes : google_compute_instance.node[n].instance_id]
  private_key        = var.private_key
  repo_url           = var.repo_url
  repo_branch        = var.repo_branch
}
