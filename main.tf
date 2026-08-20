data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

data "azurerm_virtual_network" "this" {
  name                = var.virtual_network_name
  resource_group_name = local.virtual_network_resource_group_name
}

data "azurerm_subnet" "node" {
  name                 = var.node_subnet_name
  resource_group_name  = local.virtual_network_resource_group_name
  virtual_network_name = var.virtual_network_name
}

data "azurerm_subnet" "system_node" {
  count = var.system_node_subnet_name == null ? 0 : 1

  name                 = var.system_node_subnet_name
  resource_group_name  = local.virtual_network_resource_group_name
  virtual_network_name = var.virtual_network_name
}

data "azurerm_subnet" "api_server" {
  count = var.api_server_subnet_name == null ? 0 : 1

  name                 = var.api_server_subnet_name
  resource_group_name  = local.virtual_network_resource_group_name
  virtual_network_name = var.virtual_network_name
}

data "azurerm_private_dns_zone" "this" {
  count = local.use_byo_private_dns_zone ? 1 : 0

  name                = var.private_dns_zone_name
  resource_group_name = local.private_dns_zone_resource_group_name
}

# AKS needs an identity that already exists when the cluster is created, so that it can be granted
# access to the pre-existing network and private DNS zone. A system assigned identity cannot be used
# for that, because it only comes into existence together with the cluster.
resource "azurerm_user_assigned_identity" "this" {
  location            = var.location
  name                = "${var.name}-identity"
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# Lets the cluster join nodes and load balancers to the existing virtual network.
resource "azurerm_role_assignment" "network_contributor" {
  count = var.create_role_assignments ? 1 : 0

  principal_id                     = azurerm_user_assigned_identity.this.principal_id
  scope                            = data.azurerm_virtual_network.this.id
  role_definition_name             = "Network Contributor"
  skip_service_principal_aad_check = true
}

# Lets the cluster register the API server record in the existing private DNS zone.
resource "azurerm_role_assignment" "private_dns_zone_contributor" {
  count = var.create_role_assignments && local.use_byo_private_dns_zone ? 1 : 0

  principal_id                     = azurerm_user_assigned_identity.this.principal_id
  scope                            = data.azurerm_private_dns_zone.this[0].id
  role_definition_name             = "Private DNS Zone Contributor"
  skip_service_principal_aad_check = true
}

module "aks" {
  source  = "Azure/avm-res-containerservice-managedcluster/azurerm"
  version = "0.8.1"

  location  = var.location
  name      = var.name
  parent_id = data.azurerm_resource_group.this.id
  aad_profile = {
    admin_group_object_ids = var.entra_admin_group_object_ids
    enable_azure_rbac      = true
    managed                = true
    tenant_id              = data.azurerm_client_config.current.tenant_id
  }
  api_server_access_profile = {
    authorized_ip_ranges               = local.api_server_authorized_ip_ranges
    enable_private_cluster             = var.private_cluster_enabled
    enable_private_cluster_public_fqdn = var.private_cluster_enabled ? var.private_cluster_public_fqdn_enabled : null
    enable_vnet_integration            = var.api_server_subnet_name == null ? null : true
    private_dns_zone                   = local.private_dns_zone
    subnet_id                          = one(data.azurerm_subnet.api_server[*].id)
  }
  default_agent_pool = {
    availability_zones  = var.default_node_pool.availability_zones
    count_of            = var.default_node_pool.node_count
    enable_auto_scaling = var.default_node_pool.enable_auto_scaling
    max_count           = var.default_node_pool.enable_auto_scaling ? var.default_node_pool.max_count : null
    max_pods            = var.default_node_pool.max_pods
    min_count           = var.default_node_pool.enable_auto_scaling ? var.default_node_pool.min_count : null
    name                = var.default_node_pool.name
    os_disk_size_gb     = var.default_node_pool.os_disk_size_gb
    type                = "VirtualMachineScaleSets"
    vm_size             = var.default_node_pool.vm_size
    vnet_subnet_id      = data.azurerm_subnet.node.id
  }
  dns_prefix       = var.name
  enable_telemetry = var.enable_telemetry
  fqdn_subdomain   = local.fqdn_subdomain
  # AKS Automatic places its hosted system components in a subnet of the existing network.
  hosted_system_profile = local.is_automatic && var.system_node_subnet_name != null ? {
    enabled               = true
    node_subnet_id        = data.azurerm_subnet.node.id
    system_node_subnet_id = one(data.azurerm_subnet.system_node[*].id)
  } : null
  kubernetes_version = var.kubernetes_version
  managed_identities = {
    system_assigned            = false
    user_assigned_resource_ids = [azurerm_user_assigned_identity.this.id]
  }
  network_profile = var.network_profile
  sku = {
    name = var.sku_name
    tier = var.sku_tier
  }
  tags = var.tags

  depends_on = [
    azurerm_role_assignment.network_contributor,
    azurerm_role_assignment.private_dns_zone_contributor,
  ]
}
