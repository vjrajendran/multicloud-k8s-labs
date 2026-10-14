output "master_public_ip" {
  value = azurerm_public_ip.node["master1"].ip_address
}

output "private_ips" {
  value = { for n, nic in azurerm_network_interface.node : n => nic.private_ip_address }
}
