output "endpoint" {
  value = google_container_cluster.this.endpoint
}

output "ca" {
  value = google_container_cluster.this.master_auth[0].cluster_ca_certificate
}
