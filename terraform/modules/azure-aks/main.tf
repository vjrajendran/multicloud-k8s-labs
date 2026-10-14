# AKS puts its nodes in a second resource group (MC_...). Pluralsight allows
# that one, but you can't view or manage it.
resource "azurerm_kubernetes_cluster" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group
  dns_prefix          = var.name
  sku_tier            = "Free"

  default_node_pool {
    name            = "system"
    vm_size         = var.node_size
    node_count      = var.node_count
    os_disk_size_gb = 30
  }

  identity {
    type = "SystemAssigned"
  }

  # The cluster's own outbound IP is allowed automatically
  api_server_access_profile {
    authorized_ip_ranges = var.admin_cidrs
  }
}
