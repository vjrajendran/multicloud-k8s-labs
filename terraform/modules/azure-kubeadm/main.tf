locals {
  # deploy.sh / inventory expect master1 + exactly these two workers
  nodes = {
    master1 = var.master_size
    client1 = var.worker_size
    client2 = var.worker_size
  }
}

# Every node gets a public IP: new Azure VNets have no default outbound
# internet access, and the nodes need it for apt and container images.
resource "azurerm_public_ip" "node" {
  for_each = local.nodes

  name                = "${var.name}-${each.key}-ip"
  location            = var.location
  resource_group_name = var.resource_group
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "node" {
  for_each = local.nodes

  name                = "${var.name}-${each.key}-nic"
  location            = var.location
  resource_group_name = var.resource_group

  ip_configuration {
    name                          = "primary"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.node[each.key].id
  }
}

resource "azurerm_linux_virtual_machine" "node" {
  for_each = local.nodes

  name                  = "${var.name}-${each.key}"
  computer_name         = each.key
  location              = var.location
  resource_group_name   = var.resource_group
  size                  = each.value
  admin_username        = "ubuntu" # deploy.sh assumes /home/ubuntu
  network_interface_ids = [azurerm_network_interface.node[each.key].id]

  disable_password_authentication = true

  admin_ssh_key {
    username   = "ubuntu"
    public_key = var.public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  tags = {
    Cluster = var.name
    Role    = each.key == "master1" ? "control-plane" : "worker"
  }
}

module "bootstrap" {
  source = "../kubeadm-bootstrap"

  master_public_ip   = azurerm_public_ip.node["master1"].ip_address
  master_private_ip  = azurerm_network_interface.node["master1"].private_ip_address
  worker_private_ips = [for n in ["client1", "client2"] : azurerm_network_interface.node[n].private_ip_address]
  instance_ids       = [for n in ["master1", "client1", "client2"] : azurerm_linux_virtual_machine.node[n].id]
  private_key        = var.private_key
  repo_url           = var.repo_url
  repo_branch        = var.repo_branch
}
