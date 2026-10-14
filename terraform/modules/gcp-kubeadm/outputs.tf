output "master_public_ip" {
  value = google_compute_instance.node["master1"].network_interface[0].access_config[0].nat_ip
}

output "private_ips" {
  value = { for n, vm in google_compute_instance.node : n => vm.network_interface[0].network_ip }
}
