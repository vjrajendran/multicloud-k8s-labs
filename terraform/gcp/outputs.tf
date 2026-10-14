# Read by up.sh - the same two outputs exist for every cloud.

# kubeadm clusters, one per line: "<name> <master public ip>"
output "kubeadm" {
  value = join("\n", [for name, c in module.kubeadm : "${name} ${c.master_public_ip}"])
}

# Managed clusters, one per line: "<name> <kind> <region> <server> <ca> <cert> <key>"
# ("-" = not used; GKE authenticates with gke-gcloud-auth-plugin)
output "managed" {
  sensitive = true
  value = join("\n", [
    for name, c in module.gke : "${name} gke ${local.zone} https://${c.endpoint} ${c.ca} - -"
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
    { for name, c in module.gke : name => { type = "gke", zone = local.zone } },
  )
}

output "admin_cidr" {
  value = local.admin_cidr
}

output "allowed_cidrs" {
  value = local.admin_cidrs
}
