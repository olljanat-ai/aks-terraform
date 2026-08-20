locals {
  # Authorized IP ranges only apply to a public API server; an empty list means "no restriction".
  api_server_authorized_ip_ranges = var.private_cluster_enabled || length(var.api_server_authorized_ip_ranges) == 0 ? null : var.api_server_authorized_ip_ranges
  # Azure rejects a dnsPrefix when a custom private DNS zone is used and requires an fqdnSubdomain
  # instead. AKS Automatic derives both itself.
  fqdn_subdomain                       = local.is_automatic ? null : (local.use_byo_private_dns_zone ? coalesce(var.fqdn_subdomain, var.name) : var.fqdn_subdomain)
  is_automatic                         = var.sku_name == "Automatic"
  private_dns_zone                     = var.private_cluster_enabled ? (local.use_byo_private_dns_zone ? one(data.azurerm_private_dns_zone.this[*].id) : "system") : null
  private_dns_zone_resource_group_name = coalesce(var.private_dns_zone_resource_group_name, var.resource_group_name)
  use_byo_private_dns_zone             = var.private_cluster_enabled && var.private_dns_zone_name != null
  virtual_network_resource_group_name  = coalesce(var.virtual_network_resource_group_name, var.resource_group_name)
}
