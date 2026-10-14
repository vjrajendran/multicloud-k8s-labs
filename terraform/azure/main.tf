# ---------------------------------------------------------------
# Lookups
# ---------------------------------------------------------------

data "azurerm_client_config" "current" {}

# The sandbox comes with exactly one usable resource group
data "azapi_resource_list" "groups" {
  count = var.resource_group == "" ? 1 : 0

  type                   = "Microsoft.Resources/resourceGroups@2022-09-01"
  parent_id              = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  response_export_values = ["*"]
}

locals {
  candidate_groups = var.resource_group != "" ? [var.resource_group] : [
    for g in data.azapi_resource_list.groups[0].output.value : g.name
    if !startswith(g.name, "MC_") && g.name != "NetworkWatcherRG"
  ]
}

data "azurerm_resource_group" "sandbox" {
  name = local.candidate_groups[0]
}

data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  location    = var.location != "" ? var.location : data.azurerm_resource_group.sandbox.location
  admin_cidr  = var.admin_cidr != "" ? var.admin_cidr : "${chomp(data.http.my_ip.response_body)}/32"
  admin_cidrs = distinct(concat([local.admin_cidr], var.shared_cidrs))
  kubeadm     = [for i in range(var.kubeadm_clusters) : "${terraform.workspace}-k${i + 1}"]
  managed     = [for i in range(var.managed_clusters) : "${terraform.workspace}-aks${i + 1}"]

  # Allowed Pluralsight VM sizes and their vCPUs
  vcpus = {
    Standard_A1_v2  = 1
    Standard_B1s    = 1
    Standard_B1ms   = 1
    Standard_B2s    = 2
    Standard_B2ms   = 2
    Standard_D1_v2  = 1
    Standard_DS1_v2 = 1
    Standard_D2s_v3 = 2
    Standard_D2s_v4 = 2
    Standard_D2s_v5 = 2
    Standard_F2     = 2
  }

  vms        = var.kubeadm_clusters * 3 + var.managed_clusters * var.managed_node_count
  vcpu_total = (var.kubeadm_clusters * (lookup(local.vcpus, var.master_size, 99) + 2 * lookup(local.vcpus, var.worker_size, 99)) + var.managed_clusters * var.managed_node_count * lookup(local.vcpus, var.aks_node_size, 99))
}

# Pluralsight: max 10 VMs, 10 vCPUs, 2 scale sets (one per AKS cluster), 3 nodes per AKS cluster
resource "terraform_data" "capacity" {
  input = [local.vms, local.vcpu_total]

  lifecycle {
    precondition {
      condition     = alltrue([for s in [var.master_size, var.worker_size, var.aks_node_size] : contains(keys(local.vcpus), s)])
      error_message = "VM sizes must be ones Pluralsight allows: ${join(", ", keys(local.vcpus))}."
    }
    precondition {
      condition     = local.vcpu_total <= 10 && local.vms <= 10
      error_message = "This needs ${local.vms} VMs / ${local.vcpu_total} vCPUs; a Pluralsight Azure sandbox allows 10 / 10. kubeadm clusters use 4 vCPU each, AKS nodes 2 each."
    }
    precondition {
      condition     = var.managed_clusters <= 2 && var.managed_node_count <= 3
      error_message = "Pluralsight Azure allows 2 scale sets (= 2 AKS clusters) of at most 3 nodes."
    }
    precondition {
      condition     = length(local.candidate_groups) > 0
      error_message = "No sandbox resource group found - set the resource group in labs.env."
    }
  }
}

# ---------------------------------------------------------------
# Network for the kubeadm VMs
# ---------------------------------------------------------------

resource "azurerm_virtual_network" "lab" {
  count = var.kubeadm_clusters > 0 ? 1 : 0

  name                = "${terraform.workspace}-vnet"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.sandbox.name
  address_space       = ["10.20.0.0/16"]
}

resource "azurerm_subnet" "nodes" {
  count = var.kubeadm_clusters > 0 ? 1 : 0

  name                 = "nodes"
  resource_group_name  = data.azurerm_resource_group.sandbox.name
  virtual_network_name = azurerm_virtual_network.lab[0].name
  address_prefixes     = ["10.20.1.0/24"]
}

# Traffic inside the VNet is allowed by Azure's default rules
resource "azurerm_network_security_group" "nodes" {
  count = var.kubeadm_clusters > 0 ? 1 : 0

  name                = "${terraform.workspace}-nodes"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.sandbox.name

  security_rule {
    name                       = "ssh-and-api-from-you-and-shared-users"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["22", "6443"]
    source_address_prefixes    = local.admin_cidrs
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "nodes" {
  count = var.kubeadm_clusters > 0 ? 1 : 0

  subnet_id                 = azurerm_subnet.nodes[0].id
  network_security_group_id = azurerm_network_security_group.nodes[0].id
}

# ---------------------------------------------------------------
# SSH key for the kubeadm clusters in this sandbox (Azure wants RSA)
# ---------------------------------------------------------------

resource "tls_private_key" "lab" {
  algorithm = "RSA"
  rsa_bits  = 4096
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
  source   = "../modules/azure-kubeadm"
  for_each = toset(local.kubeadm)

  name           = each.key
  location       = local.location
  resource_group = data.azurerm_resource_group.sandbox.name
  subnet_id      = azurerm_subnet.nodes[0].id
  public_key     = tls_private_key.lab.public_key_openssh
  private_key    = tls_private_key.lab.private_key_openssh
  master_size    = var.master_size
  worker_size    = var.worker_size
  repo_url       = var.repo_url
  repo_branch    = var.repo_branch

  depends_on = [terraform_data.capacity, azurerm_subnet_network_security_group_association.nodes]
}

module "aks" {
  source   = "../modules/azure-aks"
  for_each = toset(local.managed)

  name           = each.key
  location       = local.location
  resource_group = data.azurerm_resource_group.sandbox.name
  admin_cidrs    = local.admin_cidrs
  node_count     = var.managed_node_count
  node_size      = var.aks_node_size

  depends_on = [terraform_data.capacity]
}
