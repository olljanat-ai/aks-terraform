# Prototype cluster on the Automatic SKU: Azure manages node provisioning, scaling, networking
# and upgrades. Automatic always runs on the Standard tier and, on a bring-your-own network,
# always uses API Server VNet Integration.

module "aks" {
  source = "../../modules/aks"

  location            = var.location
  name                = var.cluster_name
  node_subnet_name    = var.node_subnet_name
  resource_group_name = var.resource_group_name

  virtual_network_name                = var.virtual_network_name
  virtual_network_resource_group_name = var.virtual_network_resource_group_name
  system_node_subnet_name             = var.system_node_subnet_name
  api_server_subnet_name              = var.api_server_subnet_name

  private_cluster_enabled              = var.private_cluster_enabled
  api_server_authorized_ip_ranges      = var.api_server_authorized_ip_ranges
  private_dns_zone_name                = var.private_dns_zone_name
  private_dns_zone_resource_group_name = var.private_dns_zone_resource_group_name

  sku_name = "Automatic"
  sku_tier = "Standard"

  kubernetes_version           = var.kubernetes_version
  entra_admin_group_object_ids = var.entra_admin_group_object_ids

  # Automatic ignores everything else about the node pool and provisions nodes on demand.
  default_node_pool = {
    node_count = var.node_count
  }

  network_profile = {
    outbound_type = var.outbound_type
  }

  tags = var.tags
}
