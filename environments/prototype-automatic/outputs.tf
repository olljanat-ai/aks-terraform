output "cluster_name" {
  description = "Name of the AKS cluster."
  value       = module.aks.name
}

output "cluster_resource_id" {
  description = "Resource ID of the AKS cluster."
  value       = module.aks.resource_id
}

output "identity_principal_id" {
  description = "Principal ID of the user assigned identity used by the cluster."
  value       = module.aks.identity_principal_id
}

output "node_resource_group_name" {
  description = "Name of the resource group holding the cluster infrastructure."
  value       = module.aks.node_resource_group_name
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL of the cluster, used for workload identity federation."
  value       = module.aks.oidc_issuer_url
}

output "private_fqdn" {
  description = "Private FQDN of the API server. Null for a public cluster."
  value       = module.aks.private_fqdn
}
