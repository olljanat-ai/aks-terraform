output "fqdn" {
  description = "Public FQDN of the API server. Null for a private cluster without a public FQDN."
  value       = module.aks.fqdn
}

output "identity_principal_id" {
  description = <<DESCRIPTION
Principal ID of the identity the cluster runs as - the user assigned identity created here, or the
cluster's own system assigned one where Azure requires that instead. Grant it access to resources
the cluster has to reach.
DESCRIPTION
  value       = local.system_assigned_identity ? module.aks.identity_principal_id : one(azurerm_user_assigned_identity.this[*].principal_id)
}

output "identity_resource_id" {
  description = <<DESCRIPTION
Resource ID of the user assigned identity used by the cluster. Null for a cluster running on a
system assigned identity, which is part of the cluster rather than a resource of its own.
DESCRIPTION
  value       = one(azurerm_user_assigned_identity.this[*].id)
}

output "kubelet_identity_object_id" {
  description = <<DESCRIPTION
Object ID of the identity the nodes run as. Grant it `AcrPull` on a container registry to let the
cluster pull images without a pull secret.
DESCRIPTION
  value       = try(module.aks.kubelet_identity.objectId, null)
}

output "name" {
  description = "Name of the AKS cluster."
  value       = module.aks.name
}

output "node_resource_group_id" {
  description = "Resource ID of the resource group holding the cluster infrastructure."
  value       = module.aks.node_resource_group_id
}

output "node_resource_group_name" {
  description = "Name of the resource group holding the cluster infrastructure."
  value       = module.aks.node_resource_group_name
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL of the cluster, used for workload identity federation."
  value       = module.aks.oidc_issuer_profile_issuer_url
}

output "private_fqdn" {
  description = "Private FQDN of the API server. Null for a public cluster."
  value       = module.aks.private_fqdn
}

output "resource_id" {
  description = "Resource ID of the AKS cluster."
  value       = module.aks.resource_id
}
