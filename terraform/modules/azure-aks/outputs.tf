output "host" {
  value = azurerm_kubernetes_cluster.this.kube_config[0].host
}

output "ca" {
  value     = azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate
  sensitive = true
}

output "cert" {
  value     = azurerm_kubernetes_cluster.this.kube_config[0].client_certificate
  sensitive = true
}

output "key" {
  value     = azurerm_kubernetes_cluster.this.kube_config[0].client_key
  sensitive = true
}
