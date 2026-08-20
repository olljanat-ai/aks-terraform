# Prototype cluster on the Free tier: a single system node pool, no uptime SLA, private by default.

module "aks" {
  source = "../../modules/aks"

  location            = var.location
  name                = var.cluster_name
  node_subnet_name    = var.node_subnet_name
  resource_group_name = var.resource_group_name

  virtual_network_name                = var.virtual_network_name
  virtual_network_resource_group_name = var.virtual_network_resource_group_name

  private_cluster_enabled              = var.private_cluster_enabled
  api_server_authorized_ip_ranges      = var.api_server_authorized_ip_ranges
  private_dns_zone_name                = var.private_dns_zone_name
  private_dns_zone_resource_group_name = var.private_dns_zone_resource_group_name

  sku_name = "Base"
  sku_tier = "Free"

  kubernetes_version           = var.kubernetes_version
  entra_admin_group_object_ids = var.entra_admin_group_object_ids
  default_node_pool            = var.node_pool

  network_profile = {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "cilium"
    network_dataplane   = "cilium"
    outbound_type       = var.outbound_type
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
  }

  tags = var.tags
}
