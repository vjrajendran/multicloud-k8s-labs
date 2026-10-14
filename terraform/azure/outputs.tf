# Read by up.sh - the same two outputs exist for every cloud.

# kubeadm clusters, one per line: "<name> <master public ip>"
output "kubeadm" {
  value = join("\n", [for name, c in module.kubeadm : "${name} ${c.master_public_ip}"])
}

# Managed clusters, one per line: "<name> <kind> <region> <server> <ca> <cert> <key>"
output "managed" {
  sensitive = true
  value = join("\n", [
    for name, c in module.aks : "${name} aks ${local.location} ${c.host} ${c.ca} ${c.cert} ${c.key}"
  ])
}

output "clusters" {
  value = merge(
    {
      for name, c in module.kubeadm : name => {
        type = "kubeadm"
        ssh  = "ssh -i keys/${terraform.workspace}.pem ubuntu@${c.master_public_ip}"
        ips  = c.private_ips
      }
    },
    { for name, c in module.aks : name => { type = "aks" } },
  )
}

output "resource_group" {
  value = data.azurerm_resource_group.sandbox.name
}

output "admin_cidr" {
  value = local.admin_cidr
}

output "allowed_cidrs" {
  value = local.admin_cidrs
}
